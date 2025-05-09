//
//  BluetoothManager.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import Foundation
import PolarBleSdk
import RxSwift
import CoreBluetooth
import Combine

class BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - API & Resources
    private var api: PolarBleApi!
    private let disposeBag = DisposeBag()
    private var ecgStreamingStarted = false
    private var hrStreamingStarted = false // <-- Add this flag
    private var scanDisposable: Disposable? = nil

    // MARK: - Published Data
    @Published var discoveredDevices: [PolarDeviceInfo] = []
    @Published var isConnected: Bool = false
    @Published var heartRate: Int = 0
    @Published var ecgData: [Double] = []
    @Published var last5sPeakIndices: [Int] = [] // no longer updated, kept for UI compatibility
    @Published var hrv: Double = 0.0
    @Published var accelerationData: [(timestamp: Double, x: Double, y: Double, z: Double)] = []
    @Published var verticalSpeedData: [(timestamp: Double, speed: Double)] = []
    @Published var detectedPeaks: [(timestamp: Double, value: Double)] = []
    @Published var peakIntervals: [Double] = []
    @Published var lapActive: Bool = false
    @Published var jumpEvents: [(takeoffIdx: Int, landingIdx: Int, heightCm: Double)] = []
    @Published var jumpHeights: [Double] = []
    @Published var jumpMode: Bool = false
    @Published var currentZAcceleration: Double = 0.0
    @Published var currentThreshold: Double = 0.0

    // MARK: - Buffer Settings
    let samplingRate = 130.0
    private let hrvWindow = 20.0           // seconds
    private var bufferSize: Int { Int(samplingRate * hrvWindow) }

    // MARK: - Robust HRV Calculation State
    @Published var robustHRVReady: Bool = false
    @Published var robustHRVProgress: Double = 0.0 // 0.0 ... 1.0
    @Published var robustHRVResult: RobustHRVResult? = nil
    // Removed robustHRVResultLocal earlier, so add an alias for UI compatibility:
    var robustHRVResultLocal: RobustHRVResult? {
        return robustHRVResult
    }

    // Changed from 300.0 (5 minutes) to 120.0 (2 minutes) for quicker robust analysis
    private let robustWindow: Double = 120.0 // 2 minutes
    private var robustBufferSize: Int { Int(samplingRate * robustWindow) }
    private var robustHRVCalculationTask: Task<Void, Never>? = nil
    
    // Add a timestamp to track when measurements started
    private var measurementStartTime = Date()
    // Define stabilization period (3 seconds) to ignore at the beginning
    private let stabilizationPeriod: Double = 10.0 // was 5.0, now 10s for more robust HRV

    // Store computed HRV/HR per second for the whole session
    private var computedPerSecond: [[String: Any]] = []
    private let computedPerSecondMaxCount = 60 * 60 * 2 // e.g., keep max 2 hours (7200 entries)

    // Only keep the last 2 minutes of raw ECG data for export and plotting,
    // and keep a rolling buffer for robust HRV calculation.
    private let rawECGWindow: Double = 120.0 // seconds (for plot/export and robust HRV)
    private var rawECGBufferSize: Int { Int(samplingRate * rawECGWindow) }

    // --- Robust HRV buffers: separate for ECG and RR ---
    private let robustECGWindow: Double = 120.0 // seconds (2 min for robust HRV from ECG)
    private var robustECGBufferSize: Int { Int(samplingRate * robustECGWindow) }
    private var robustECGBuffer: [Double] = []

    private let robustRRWindow: Double = 120.0 // seconds (2 min for robust HRV from RR)
    private var robustRRBufferSize: Int { Int(robustRRWindow) } // 1Hz RR, so 120 values

    // Recording state
    @Published var isRecording: Bool = false
    private var sessionFileURL: URL? = nil
    private var sessionFileHandle: FileHandle? = nil

    // --- RR interval buffer from Polar HR streaming (in seconds) ---
    private var rrBuffer: [Double] = []
    // Removed rrBufferLocal

    private let rrBufferWindow: Double = 120.0 // seconds (2 minutes)
    private var rrBufferSize: Int { Int((1000.0 / samplingRate) * rrBufferWindow) } // conservative estimate

    private var accStreamingStarted = false
    private let accSamplingRate = 50.0 // Polar H10 default for ACC

    private let peakDetectionWindow: Double = 10.0 // seconds for dynamic threshold
    private let minPeakInterval: Double = 1.0 // seconds between peaks

    private var lastPeakTimestamp: Double = 0

    override init() {
        super.init()
        // Enable HR and ECG-over-BLE streaming
        let features: Set<PolarBleSdkFeature> = [.feature_hr, .feature_polar_online_streaming]
        api = PolarBleApiDefaultImpl.polarImplementation(DispatchQueue.main, features: features)
        api.polarFilter(true)
        api.deviceFeaturesObserver = self
        api.observer = self
        api.deviceInfoObserver = self
        api.powerStateObserver = self
        // Start robust HRV calculation after init, but delay until ECG streaming is actually started
        // and ensure only one timer/task is running
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(startRobustHRVIfNeeded),
            name: .didAppendECGSamples,
            object: nil
        )
        // Observe ecgData changes to trigger background processing
        $ecgData
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] _ in
                self?.processECGDataAsync()
            }
            .store(in: &cancellables)
    }

    // Store for Combine subscriptions
    private var cancellables: Set<AnyCancellable> = []
    // Add a serial queue for background processing to avoid overlapping work
    private let processingQueue = DispatchQueue(label: "PolarECG.BluetoothManager.processing")

    // MARK: - Robust HRV Progress Timer (safe, avoids leaks)
    private var robustProgressTimer: Timer?
    private var robustProgressTimerStarted = false

    @objc private func startRobustHRVIfNeeded() {
        // Start only once, when data is coming in
        guard !robustProgressTimerStarted else { return }
        robustProgressTimerStarted = true
        startRobustHRVProgressTimer()
        startRobustHRVCalculation()
    }

    private func startRobustHRVProgressTimer() {
        robustProgressTimer?.invalidate()
        robustProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Use robustECGBuffer for progress, not ecgData
            let progress = min(Double(self.robustECGBuffer.count) / Double(self.robustBufferSize), 1.0)
            self.robustHRVProgress = progress
            if progress < 1.0 {
                self.robustHRVReady = false
            }
            // Reduce debug output frequency
            if Int(progress * 100) % 5 == 0 || progress >= 1.0 {
                print("Robust HRV progress: \(progress) (\(self.robustECGBuffer.count)/\(self.robustBufferSize))")
            }
        }
        RunLoop.main.add(robustProgressTimer!, forMode: .common)
    }

    deinit {
        robustProgressTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Scanning & Connection

    /// Starts BLE scan and collects found Polar devices
    func startScan() {
        discoveredDevices.removeAll()
        // Dispose previous scan if running
        scanDisposable?.dispose()
        scanDisposable = api.searchForDevice()
            .subscribe(onNext: { [weak self] deviceInfo in
                guard let self = self else { return }
                if (!self.discoveredDevices.contains(where: { $0.deviceId == deviceInfo.deviceId })) {
                    self.discoveredDevices.append(deviceInfo)
                }
            }, onError: { error in
                print("Scan error:", error)
            })
        scanDisposable?.disposed(by: disposeBag)
    }

    /// Connects to the selected device
    func connect(to deviceId: String) {
        try? api.connectToDevice(deviceId)
        // Stop scanning when a device is selected
        scanDisposable?.dispose()
        scanDisposable = nil
    }

    // MARK: - Data Streaming

    private func startEcgStreaming(deviceId: String) {
        api.requestStreamSettings(deviceId, feature: .ecg)
            .subscribe(onSuccess: { [weak self] settings in
                self?.api.startEcgStreaming(deviceId, settings: settings)
                    .subscribe(onNext: { ecgSample in
                        let voltSamples = ecgSample.map { Double($0.voltage) / 1000.0 } // scale from µV to mV for better plotting
                        DispatchQueue.main.async {
                            self?.appendEcgSamples(voltSamples)
                        }
                    }, onError: { error in
                        print("ECG streaming error:", error)
                    })
                    .disposed(by: self!.disposeBag)
            }, onFailure: { error in
                print("Failed to request ECG settings:", error)
            })
            .disposed(by: disposeBag)
    }

    private func appendEcgSamples(_ samples: [Double]) {
        // Step 1: center signal around zero
        let mean = samples.reduce(0, +) / Double(samples.count)
        let demeaned = samples.map { $0 - mean }

        // Step 2: clamp to remove spikes
        let clamped = demeaned.map { min(max($0, -3.0), 3.0) }

        // Step 3: smooth the signal
        let smoothed = movingAverage(clamped, windowSize: 3)

        // Use DispatchQueue.main.async to ensure UI updates happen on main thread
        // This helps provide smoother rendering
        DispatchQueue.main.async {
            // Record start time for the first batch of data
            if self.ecgData.isEmpty {
                self.measurementStartTime = Date()
            }
            
            self.ecgData.append(contentsOf: smoothed)
            // Only keep the last 2 minutes of raw ECG data for UI/export
            if self.ecgData.count > self.rawECGBufferSize {
                self.ecgData.removeFirst(self.ecgData.count - self.rawECGBufferSize)
            }

            // --- Maintain a larger buffer for robust HRV calculation ---
            self.robustECGBuffer.append(contentsOf: smoothed)
            if self.robustECGBuffer.count > self.robustECGBufferSize {
                self.robustECGBuffer.removeFirst(self.robustECGBuffer.count - self.robustECGBufferSize)
            }

            // --- Compute and store per-second HRV/HR values ---
            // Only trigger if enough new data (e.g., at least 1s worth)
            if smoothed.count >= Int(self.samplingRate) {
                self.updateComputedPerSecondAndStream()
            }

            // Reduce debug output frequency to avoid console spam
            if self.ecgData.count % 100 == 0 || self.ecgData.count >= self.robustBufferSize {
                print("ECG buffer count: \(self.ecgData.count), robustBufferSize: \(self.robustBufferSize), progress: \(Double(self.ecgData.count) / Double(self.robustBufferSize))")
            }
            
            NotificationCenter.default.post(name: .didAppendECGSamples, object: nil)
        }
    }

    // Compute and store per-second HRV/HR values (append only new seconds)
    private func updateComputedPerSecond() {
        let windowBeats = Int(hrvWindow * 2)
        guard windowBeats > 0 else { return }
        // --- Polar RR ---
        if rrBuffer.count >= windowBeats {
            let totalSeconds = Int(Double(rrBuffer.count) / 2.0)
            let alreadyComputed = computedPerSecond.filter { $0["source"] as? String == "polar" }.count
            let startTime = Date().addingTimeInterval(-Double(rrBuffer.count) / 2.0)
            for sec in alreadyComputed..<totalSeconds {
                let endIdx = min(rrBuffer.count, (sec + 1) * 2)
                let startIdx = max(0, endIdx - windowBeats)
                if startIdx >= 0, endIdx <= rrBuffer.count, startIdx < endIdx {
                    let windowRR = Array(rrBuffer[startIdx..<endIdx])
                    let rmssd = HRVCalculator.computeRMSSD(from: windowRR)
                    let sdnn = HRVCalculator.computeSDNN(from: windowRR)
                    let meanHR = HRVCalculator.computeMeanHR(from: windowRR)
                    let timestamp = ISO8601DateFormatter().string(from: startTime.addingTimeInterval(Double(endIdx) / 2.0))
                    computedPerSecond.append([
                        "timestamp": timestamp,
                        "rmssd": rmssd,
                        "sdnn": sdnn,
                        "meanHR": meanHR,
                        "source": "polar"
                    ])
                }
            }
        }
        // Removed local RR HRV computation
        // Limit memory usage
        if computedPerSecond.count > computedPerSecondMaxCount {
            computedPerSecond.removeFirst(computedPerSecond.count - computedPerSecondMaxCount)
        }
    }

    // Compute and stream per-second HRV/HR values (append only new seconds)
    private var lastStreamedSecond: Int = 0
    private func updateComputedPerSecondAndStream() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isRecording, let _ = self.sessionFileHandle else { return }
            let windowBeats = Int(self.hrvWindow * 2)
            guard windowBeats > 0, self.rrBuffer.count >= windowBeats else { return }
            let totalSeconds = Int(Double(self.rrBuffer.count) / 2.0)
            let startTime = Date().addingTimeInterval(-Double(self.rrBuffer.count) / 2.0)
            for sec in self.lastStreamedSecond..<totalSeconds {
                let endIdx = min(self.rrBuffer.count, (sec + 1) * 2)
                let startIdx = max(0, endIdx - windowBeats)
                if startIdx >= 0, endIdx <= self.rrBuffer.count, startIdx < endIdx {
                    let windowRR = Array(self.rrBuffer[startIdx..<endIdx])
                    let rmssd = HRVCalculator.computeRMSSD(from: windowRR)
                    let sdnn = HRVCalculator.computeSDNN(from: windowRR)
                    let meanHR = HRVCalculator.computeMeanHR(from: windowRR)
                    let timestamp = ISO8601DateFormatter().string(from: startTime.addingTimeInterval(Double(endIdx) / 2.0))
                    let dict: [String: Any] = [
                        "timestamp": timestamp,
                        "rmssd": rmssd,
                        "sdnn": sdnn,
                        "meanHR": meanHR
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
                       let fileHandle = self.sessionFileHandle {
                        fileHandle.write(data)
                        if let newline = "\n".data(using: .utf8) {
                            fileHandle.write(newline)
                        }
                    }
                }
            }
            self.lastStreamedSecond = totalSeconds
        }
    }

    private func movingAverage(_ input: [Double], windowSize: Int) -> [Double] {
        guard windowSize > 1, input.count >= windowSize else { return input }
        var result: [Double] = []
        for i in 0..<(input.count - windowSize + 1) {
            let window = input[i..<(i + windowSize)]
            result.append(window.reduce(0, +) / Double(windowSize))
        }
        // pad to keep length
        if let last = result.last {
            result.append(contentsOf: Array(repeating: last, count: input.count - result.count))
        }
        return result
    }

    func exportECGDataToFile() -> URL? {
        // Only export the last 2 minutes of raw ECG data for export/plot
        let ecgExport = Array(ecgData.suffix(rawECGBufferSize))

        // Read all computed values from the session file (if available)
        var hrvPerSecond: [[String: Any]] = []
        if let sessionFileURL = sessionFileURL,
           let fileHandle = try? FileHandle(forReadingFrom: sessionFileURL) {
            fileHandle.seek(toFileOffset: 0)
            let content = fileHandle.readDataToEndOfFile()
            if let string = String(data: content, encoding: .utf8) {
                for line in string.split(separator: "\n") {
                    if let data = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        hrvPerSecond.append(obj)
                    }
                }
            }
        }

        // --- Robust HRV summary (if available) ---
        var robustSummary: [String: Any]? = nil
        if let robust = robustHRVResult {
            robustSummary = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "windowSeconds": Int(robustWindow),
                "rmssd": robust.rmssd,
                "sdnn": robust.sdnn,
                "meanHR": robust.meanHR,
                "nn50": robust.nn50,
                "pnn50": robust.pnn50,
                "beats": robust.rrCount + 1
            ]
        }

        // Ensure computedPerSecond is up-to-date before export
        self.updateComputedPerSecond()

        let exportData: [String: Any] = [
            "samplingRate": samplingRate,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "hrvPerSecond": computedPerSecond, // full session HRV data per second
            "ecg": ecgExport,
            "robustHRVSummary": robustSummary as Any
        ]

        guard JSONSerialization.isValidJSONObject(exportData) else {
            print("Invalid JSON object.")
            return nil
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = documentsURL.appendingPathComponent("ecg_export_\(Date().timeIntervalSince1970).json")
            try jsonData.write(to: fileURL)
            return fileURL
        } catch {
            print("Failed to write ECG export:", error)
            return nil
        }
    }

    /// Computes HRV (RMSSD, SDNN, meanHR) for every second using a sliding 20s window, starting after the first 20s of data.
    private func computeHRVPerSecondSlidingWindow() -> [[String: Any]] {
        let windowBeats = Int(hrvWindow * 2)
        guard windowBeats > 0, rrBuffer.count >= windowBeats else { return [] }
        let totalSeconds = Int(Double(rrBuffer.count) / 2.0)
        var result: [[String: Any]] = []
        let startTime = Date().addingTimeInterval(-Double(rrBuffer.count) / 2.0)
        for sec in 0..<totalSeconds {
            let endIdx = min(rrBuffer.count, (sec + 1) * 2)
            let startIdx = max(0, endIdx - windowBeats)
            let windowRR = Array(rrBuffer[startIdx..<endIdx])
            let rmssd = HRVCalculator.computeRMSSD(from: windowRR)
            let sdnn = HRVCalculator.computeSDNN(from: windowRR)
            let meanHR = HRVCalculator.computeMeanHR(from: windowRR)
            let timestamp = ISO8601DateFormatter().string(from: startTime.addingTimeInterval(Double(endIdx) / 2.0))
            result.append([
                "timestamp": timestamp,
                "rmssd": rmssd,
                "sdnn": sdnn,
                "meanHR": meanHR
            ])
        }
        return result
    }

    /// Computes HRV (RMSSD, SDNN, meanHR) for every second of the available ECG data (using the last 20s for each second)
    private func computeHRVPerSecond() -> [[String: Any]] {
        // Use RR buffer if available
        guard rrBuffer.count > 0 else { return [] }
        let windowBeats = Int(hrvWindow * 2)
        let totalSeconds = Int(Double(rrBuffer.count) / 2.0)
        var result: [[String: Any]] = []
        for sec in 0..<totalSeconds {
            let endIdx = min(rrBuffer.count, (sec + 1) * 2)
            let startIdx = max(0, endIdx - windowBeats)
            let windowRR = Array(rrBuffer[startIdx..<endIdx])
            let rmssd = HRVCalculator.computeRMSSD(from: windowRR)
            let sdnn = HRVCalculator.computeSDNN(from: windowRR)
            let meanHR = HRVCalculator.computeMeanHR(from: windowRR)
            let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(totalSeconds - sec)))
            result.append([
                "timestamp": timestamp,
                "rmssd": rmssd,
                "sdnn": sdnn,
                "meanHR": meanHR
            ])
        }
        return result
    }
    
    // --- HRV over last 20s window ---
    /// RR intervals (s) over the last 20s window, using Polar RR buffer if available
    var rrIntervals: [Double] {
        let windowBeats = Int(hrvWindow * 2)
        // Always return up to the last 20 RR intervals, even if fewer are available
        if rrBuffer.count > 0 {
            return Array(rrBuffer.suffix(min(windowBeats, rrBuffer.count)))
        }
        return []
    }

    /// Computes RMSSD (ms) over the last 20 s using Polar RR intervals
    var hrvRMSSD: Double {
        // Show HRV even if fewer than 20 samples are available
        HRVCalculator.computeRMSSD(from: rrIntervals)
    }

    /// Computes SDNN (ms) over the last 20 s using Polar RR intervals
    var hrvSDNN: Double {
        HRVCalculator.computeSDNN(from: rrIntervals)
    }

    /// Computes mean heart rate (BPM) over the last 20 s using Polar RR intervals
    var meanHeartRate: Double {
        HRVCalculator.computeMeanHR(from: rrIntervals)
    }

    /// Indices of detected peaks in the last 5s window, relative to ecgData
    private func processECGDataAsync() {
        // Only update HRV (RMSSD) over last 20s using polar RR buffer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Show HRV even if fewer than 20 samples are available
            let rmssd = self.rrIntervals.count > 1 ? HRVCalculator.computeRMSSD(from: self.rrIntervals) : 0.0
            DispatchQueue.main.async { self.hrv = rmssd }
        }
    }

    private func startHrStreaming(deviceId: String) {
        api.startHrStreaming(deviceId)
            .subscribe(onNext: { [weak self] hrData in
                guard let self = self else { return }
                if let sample = hrData.first {
                    DispatchQueue.main.async {
                        self.heartRate = Int(sample.hr)
                        NSLog("HR    BPM: \(sample.hr) rrs: \(sample.rrsMs) rrAvailable: \(sample.rrAvailable) contact status: \(sample.contactStatus) contact supported: \(sample.contactStatusSupported)")
                        if sample.rrAvailable {
                            let newRRs = sample.rrsMs.map { Double($0) / 1000.0 }
                            self.rrBuffer.append(contentsOf: newRRs)
                            if self.rrBuffer.count > self.robustRRBufferSize {
                                self.rrBuffer.removeFirst(self.rrBuffer.count - self.robustRRBufferSize)
                            }
                            // Update HRV immediately after new RR intervals are appended, even if < 20 samples
                            let rmssd = self.rrIntervals.count > 1 ? HRVCalculator.computeRMSSD(from: self.rrIntervals) : 0.0
                            self.hrv = rmssd
                        }
                    }
                }
            }, onError: { error in
                print("HR streaming error:", error)
            })
            .disposed(by: disposeBag)
    }

    private func startAccStreaming(deviceId: String) {
        api.requestStreamSettings(deviceId, feature: .acc)
            .subscribe(onSuccess: { [weak self] settings in
                self?.api.startAccStreaming(deviceId, settings: settings)
                    .subscribe(onNext: { accSamples in
                        // Each accSamples is [PolarAccelerometerData]
                        // Convert timestamp to Double for compatibility
                        let accTuples = accSamples.map { sample in
                            (
                                timestamp: Double(sample.timeStamp),
                                x: Double(sample.x) / 1000.0, // convert from mg to g
                                y: Double(sample.y) / 1000.0,
                                z: Double(sample.z) / 1000.0
                            )
                        }
                        DispatchQueue.main.async {
                            self?.appendAccSamples(accTuples)
                        }
                    }, onError: { error in
                        print("ACC streaming error:", error)
                    })
                    .disposed(by: self!.disposeBag)
            }, onFailure: { error in
                print("Failed to request ACC settings:", error)
            })
            .disposed(by: disposeBag)
    }

    private func appendAccSamples(_ samples: [(timestamp: Double, x: Double, y: Double, z: Double)]) {
        accelerationData.append(contentsOf: samples)
        let maxCount = Int(accSamplingRate * 120.0)
        if accelerationData.count > maxCount {
            accelerationData.removeFirst(accelerationData.count - maxCount)
        }
        computeVerticalSpeed()
        detectPeaksIfActive()
        if jumpMode { detectJumps() }
    }

    private func computeVerticalSpeed() {
        guard accelerationData.count > 1 else { return }
        var speeds: [(timestamp: Double, speed: Double)] = []
        for i in 1..<accelerationData.count {
            let dt = (accelerationData[i].timestamp - accelerationData[i-1].timestamp) / 1000.0 // ms to s
            if dt > 0 {
                let dz = accelerationData[i].z - accelerationData[i-1].z
                let speed = dz / dt
                speeds.append((timestamp: accelerationData[i].timestamp, speed: speed))
            }
        }
        verticalSpeedData = speeds
    }

    private func detectPeaksIfActive() {
        guard lapActive else { 
            // Clear peaks when detection is inactive
            if (!detectedPeaks.isEmpty) {
                detectedPeaks = []
                peakIntervals = []
            }
            return 
        }
        
        // Only use last 1 minute for peak detection
        let now = accelerationData.last?.timestamp ?? 0
        let oneMinuteAgo = now - 60_000 // ms
        let recent = accelerationData.filter { $0.timestamp >= oneMinuteAgo }
        
        guard recent.count > 5 else { 
            print("Too few acceleration samples for peak detection: \(recent.count)")
            return 
        }
        
        // Dynamic threshold: mean + 1.0*stddev of last 10s (even more sensitive)
        let windowMs = peakDetectionWindow * 1000
        let windowArray: ArraySlice<(timestamp: Double, x: Double, y: Double, z: Double)>
        if let firstIdx = recent.firstIndex(where: { $0.timestamp >= (now - windowMs) }) {
            windowArray = recent[firstIdx...]
        } else {
            windowArray = recent[recent.startIndex...]
        }
        
        let zVals: [Double] = Array(windowArray.map { $0.z })
        let mean = zVals.reduce(0, +) / Double(zVals.count)
        let std = sqrt(zVals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(zVals.count))
        
        // Lower threshold for higher sensitivity (1.0 instead of 1.5)
        let threshold = mean + 1.0 * std
        
        // Update current values for UI display
        if let lastZ = recent.last?.z {
            currentZAcceleration = lastZ
        }
        currentThreshold = threshold
        
        print("Peak detection - mean: \(mean), std: \(std), threshold: \(threshold), samples: \(zVals.count)")

        // Find peaks above threshold, min interval 0.3s (reduced from 0.5s)
        var newPeaks: [(timestamp: Double, value: Double)] = []
        let lastMinutePeaks = detectedPeaks.filter { $0.timestamp >= oneMinuteAgo }
        var lastPeak = lastMinutePeaks.last?.timestamp ?? 0
        
        // Use absolute peak detection rather than only looking for positive peaks
        for i in 1..<(recent.count-1) {
            let prev = recent[i-1].z
            let curr = recent[i].z
            let next = recent[i+1].z
            let t = recent[i].timestamp
            
            // Detect both positive and negative peaks (abs difference from mean)
            let absFromMean = abs(curr - mean)
            
            // Use absolute value criteria rather than just being above threshold
            if absFromMean > abs(threshold - mean) && 
               abs(curr) > abs(prev) && abs(curr) > abs(next) && 
               (t - lastPeak) > 300 { // 300ms minimum interval
                
                newPeaks.append((timestamp: t, value: curr))
                lastPeak = t
                print("Peak detected at \(t) with value \(curr), abs from mean: \(absFromMean)")
            }
        }
        
        // Only keep last 1 minute of peaks, but ensure we have at least new peaks
        let combinedPeaks = lastMinutePeaks + newPeaks
        detectedPeaks = Array(combinedPeaks.suffix(max(20, newPeaks.count)))
        
        print("Total active peaks: \(detectedPeaks.count), new peaks: \(newPeaks.count)")
        
        // Compute intervals
        let sortedTimestamps = detectedPeaks.map { $0.timestamp / 1000.0 }.sorted()
        var intervals: [Double] = []
        for i in 1..<sortedTimestamps.count {
            intervals.append(sortedTimestamps[i] - sortedTimestamps[i-1])
        }
        peakIntervals = intervals
    }

    // Helper struct for jump detection
    struct AccSample {
        let t: Double
        let ax: Double
        let ay: Double
        let az: Double
    }

    // 1-pole high-pass filter for vertical acceleration
    private func highPass(_ signal: [Double], cutoffHz fc: Double, sampleRate fs: Double) -> [Double] {
        let dt = 1.0 / fs
        let RC = 1.0 / (2 * Double.pi * fc)
        let alpha = RC / (RC + dt)
        var out = Array(repeating: 0.0, count: signal.count)
        var prevY = 0.0
        var prevX = 0.0
        for i in 0..<signal.count {
            let x = signal[i]
            let y = alpha * (prevY + x - prevX)
            out[i] = y
            prevY = y
            prevX = x
        }
        return out
    }

    // VERY simple and direct jump detection with proper bounds checking
    func detectJumps() {
        guard jumpMode else { return }
        
        // Clear previous test jumps
        jumpEvents = []
        jumpHeights = []
        
        // Use the raw Z-axis data directly
        let fs = accSamplingRate
        let rawSamples = accelerationData.suffix(Int(5.0 * fs)) // Last 5 seconds
        
        guard rawSamples.count > 10 else {
            print("Not enough samples for jump detection")
            return
        }
        
        // Debug output
        print("Raw samples count: \(rawSamples.count)")
        
        // Display current value
        if let lastSample = rawSamples.last {
            currentZAcceleration = lastSample.z
            print("Current Z: \(lastSample.z)")
        }
        
        // Just look for a simple pattern of down-then-up in z-axis
        let zValues = rawSamples.map { $0.z }
        
        // Find min and max with bounds checking
        guard !zValues.isEmpty, 
              let minZ = zValues.min(),
              let maxZ = zValues.max() else { 
            print("Empty Z values array") 
            return 
        }
        
        // If we have significant movement, consider it a jump
        let range = maxZ - minZ
        print("Z range: \(range) (min: \(minZ), max: \(maxZ))")
        
        // Very sensitive threshold - just 0.3g difference required
        if range > 0.3 {
            // Find index of min and max with safe unwrapping
            guard let minIdx = zValues.firstIndex(of: minZ),
                  let maxIdx = zValues.firstIndex(of: maxZ),
                  minIdx < zValues.count,
                  maxIdx < zValues.count,
                  abs(maxIdx - minIdx) > 3 else { 
                print("Invalid indices for min/max") 
                return 
            }
            
            // Create a jump with height based on the z-range
            let takeoffIdx = min(minIdx, maxIdx)
            let landingIdx = max(minIdx, maxIdx)
            let flightSeconds = Double(landingIdx - takeoffIdx) / fs
            
            // Calculate height using flight time
            let heightCm = 100.0 * 0.5 * 9.81 * pow(flightSeconds/2, 2)
            
            jumpEvents = [(takeoffIdx: takeoffIdx, landingIdx: landingIdx, heightCm: heightCm)]
            jumpHeights = [heightCm]
            
            print("DETECTED JUMP! Height: \(heightCm)cm, Flight time: \(flightSeconds)s")
            
            // Force update the UI
            objectWillChange.send()
        }
    }

    // Main jump detection function - improved with more sensitivity and debug info
    private func detectJumpsOld() {
        guard jumpMode else { return }
        
        // Always clear previous jumps when detection runs to avoid showing only test jumps
        if !jumpEvents.isEmpty && !jumpHeights.isEmpty {
            print("Clearing previous jump events before new detection")
            // Only keep the most recent test jump if needed for UI
            let lastTestJump = jumpHeights.count == 1 && jumpHeights.first! == 30.8 ? jumpEvents.first : nil
            jumpEvents = lastTestJump != nil ? [lastTestJump!] : []
            jumpHeights = lastTestJump != nil ? [30.8] : []
        }
        
        // SIMPLIFIED JUMP DETECTION - focused on z-axis with minimal processing
        let fs = accSamplingRate
        let windowSec = 6.0  // Use a shorter window - last 6 seconds
        
        // Get the very latest acceleration samples
        let rawSamples = accelerationData.suffix(Int(windowSec * fs))
        guard rawSamples.count > Int(fs) else {
            print("Not enough acceleration samples for jump detection: \(rawSamples.count)")
            return
        }
        
        // Use the z-axis directly with minimal processing
        let timestamps = rawSamples.map { $0.timestamp / 1000.0 } // ms to s
        let zValues = rawSamples.map { $0.z }
        
        // Debug - print what we're seeing
        if let lastZ = zValues.last {
            print("Current Z value: \(lastZ)g (raw)")
            currentZAcceleration = lastZ
        }
        
        // Calculate a simple moving average to reduce noise
        let smoothWindow = 5 // samples
        var smoothedZ = zValues
        if zValues.count > smoothWindow {
            smoothedZ = []
            for i in 0..<(zValues.count - smoothWindow + 1) {
                let avgZ = zValues[i..<(i+smoothWindow)].reduce(0, +) / Double(smoothWindow)
                smoothedZ.append(avgZ)
            }
            // Pad to maintain length
            while smoothedZ.count < zValues.count {
                smoothedZ.append(smoothedZ.last ?? 0)
            }
        }
        
        // Simple differentiation to detect changes
        var deltaZ = [0.0]
        for i in 1..<smoothedZ.count {
            deltaZ.append(smoothedZ[i] - smoothedZ[i-1])
        }
        
        // VERY SENSITIVE thresholds for jump detection
        let takeoffThresh = -0.15 // Much more sensitive
        let landingThresh = 0.15  // Much more sensitive
        
        // Detect jumps using simple heuristics
        var events: [(takeoffIdx: Int, landingIdx: Int, heightCm: Double)] = []
        var heights: [Double] = []
        var i = 0
        
        // Advanced debug output
        print("Jump detection running with \(zValues.count) samples, thresholds: \(takeoffThresh)/\(landingThresh)")
        
        while i < deltaZ.count - 1 {
            // Look for rapid downward acceleration (takeoff)
            if deltaZ[i] < takeoffThresh {
                let takeOffIdx = i
                print("Potential takeoff at idx \(takeOffIdx), value: \(deltaZ[takeOffIdx])")
                
                // Find subsequent upward acceleration (landing)
                var landIdx = i
                var foundLanding = false
                
                // Search for up to 1 second for landing
                let maxSearchSamples = Int(fs * 1.0)
                for j in i+1..<min(i + maxSearchSamples, deltaZ.count) {
                    if deltaZ[j] > landingThresh {
                        landIdx = j
                        foundLanding = true
                        print("Potential landing at idx \(landIdx), value: \(deltaZ[landIdx])")
                        break
                    }
                }
                
                if foundLanding && takeOffIdx < landIdx {
                    let takeoffTime = timestamps[takeOffIdx]
                    let landingTime = timestamps[min(landIdx, timestamps.count - 1)]
                    let tFlight = landingTime - takeoffTime
                    
                    // Allow even shorter flight times for testing
                    if tFlight > 0.05 && tFlight < 2.0 {
                        // h = 1/8 * g * t²
                        let h = 0.5 * 9.81 * pow(tFlight/2, 2)
                        let heightCm = h * 100.0
                        
                        // More lenient height detection
                        if heightCm > 1.0 && heightCm < 200.0 {
                            events.append((takeoffIdx: takeOffIdx, landingIdx: landIdx, heightCm: heightCm))
                            heights.append(heightCm)
                            print("JUMP DETECTED! Flight time: \(tFlight)s, height: \(heightCm) cm")
                        }
                    }
                    i = landIdx + Int(fs * 0.5) // Skip ahead 0.5s
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        
        // Update the results if we found any jumps
        if !events.isEmpty {
            jumpEvents = events
            jumpHeights = heights
            print("Total jumps detected: \(events.count)")
        } else {
            print("No jumps detected in this pass")
        }
    }

    func startRobustHRVCalculation() {
        robustHRVCalculationTask?.cancel()
        robustHRVReady = false
        robustHRVResult = nil
        // Removed robustHRVResultLocal

        robustHRVCalculationTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while true {
                if self.robustECGBuffer.count < self.robustECGBufferSize || self.rrBuffer.count < self.robustRRBufferSize {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s delay
                    continue
                }
                let stabilizationSamples = Int(self.samplingRate * self.stabilizationPeriod)
                var windowData = Array(self.robustECGBuffer.suffix(self.robustECGBufferSize))
                let secondsSinceStart = Date().timeIntervalSince(self.measurementStartTime)
                if secondsSinceStart < self.stabilizationPeriod + self.robustECGWindow {
                    let samplesToSkip = min(stabilizationSamples, windowData.count/4)
                    windowData = Array(windowData.dropFirst(samplesToSkip))
                }
                // Robust HRV from Polar RR intervals only:
                let rrPolar = Array(self.rrBuffer.suffix(self.robustRRBufferSize))
                let robustPolar: RobustHRVResult? = rrPolar.count > 1 ? {
                    let rmssd = HRVCalculator.computeRMSSD(from: rrPolar)
                    let sdnn = HRVCalculator.computeSDNN(from: rrPolar)
                    let meanHR = HRVCalculator.computeMeanHR(from: rrPolar)
                    let nn50 = HRVCalculator.computeNN50(from: rrPolar)
                    let pnn50 = HRVCalculator.computePNN50(from: rrPolar)
                    return RobustHRVResult(
                        rmssd: rmssd,
                        sdnn: sdnn,
                        meanHR: meanHR,
                        nn50: nn50,
                        pnn50: pnn50,
                        rrCount: rrPolar.count
                    )
                }() : nil

                await MainActor.run {
                    self.robustHRVResult = robustPolar
                    self.robustHRVReady = true
                    self.robustHRVProgress = 1.0
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stopRobustHRVCalculation() {
        robustHRVCalculationTask?.cancel()
        robustHRVCalculationTask = nil
        robustHRVReady = false
        robustHRVProgress = 0.0
        robustHRVResult = nil
    }

    // MARK: - Recording Control

    func startRecording() {
        stopRecording() // Ensure previous session is closed

        // Create (or replace) the session file
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent("ecg_session_\(Date().timeIntervalSince1970).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        sessionFileURL = fileURL
        sessionFileHandle = try? FileHandle(forWritingTo: fileURL)
        isRecording = true
        print("Recording started: \(fileURL.path)")
    }

    func stopRecording() {
        isRecording = false
        sessionFileHandle?.closeFile()
        sessionFileHandle = nil
        sessionFileURL = nil
        // Clean up buffers to free memory
        computedPerSecond.removeAll()
        ecgData.removeAll()
        robustECGBuffer.removeAll()
        rrBuffer.removeAll()
        lastStreamedSecond = 0
        accelerationData.removeAll()
        verticalSpeedData.removeAll()
        print("Recording stopped")
    }

    // Lap control
    func toggleLapActive() {
        lapActive.toggle()
        if (!lapActive) {
            // Optionally, clear peaks/intervals when pausing
            // detectedPeaks.removeAll()
            // peakIntervals.removeAll()
        }
    }

    // Export peaks and intervals as CSV
    func exportPeaksToFile() -> URL? {
        let header = "timestamp,value\n"
        let peakLines = detectedPeaks.map { "\($0.timestamp),\($0.value)" }.joined(separator: "\n")
        let intervalHeader = "\nintervals (s)\n"
        let intervalLines = peakIntervals.map { String(format: "%.3f", $0) }.joined(separator: "\n")
        let csv = header + peakLines + intervalHeader + intervalLines
        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = documentsURL.appendingPathComponent("acc_peaks_\(Date().timeIntervalSince1970).csv")
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("Failed to write peaks export:", error)
            return nil
        }
    }

    // Test function to generate artificial peaks for testing
    func testPeakDetection() {
        // Create artificial peaks at different heights
        let now = Date().timeIntervalSince1970 * 1000 // current time in ms
        var testPeaks: [(timestamp: Double, value: Double)] = []
        
        // Generate 5 test peaks
        for i in 0..<5 {
            let timestamp = now - Double(i * 1000) // 1 second apart
            let value = 1.0 + Double(i) * 0.2 // Increasing height
            testPeaks.append((timestamp: timestamp, value: value))
        }
        
        // Add them to detected peaks
        detectedPeaks = testPeaks + detectedPeaks
        
        // Calculate intervals
        var testIntervals: [Double] = []
        for _ in 1..<5 {
            testIntervals.append(1.0) // 1 second intervals
        }
        
        peakIntervals = testIntervals + peakIntervals
        
        print("Added 5 test peaks for visualization")
    }

    // Create an extremely obvious test pattern that will definitely appear
    func testJumpDetection() {
        print("Creating TEST JUMP")
        
        // Create an obvious test jump that will definitely be visible
        let takeoffIdx = 10
        let landingIdx = 30
        let heightCm = 30.8
        
        jumpEvents = [(takeoffIdx: takeoffIdx, landingIdx: landingIdx, heightCm: heightCm)]
        jumpHeights = [heightCm]
        
        print("Created TEST JUMP: height \(heightCm)cm")
        
        // Force refresh
        objectWillChange.send()
    }
}

// MARK: - Polar SDK Observers

extension BluetoothManager: PolarBleApiObserver, PolarBleApiDeviceInfoObserver, PolarBleApiDeviceFeaturesObserver, PolarBleApiPowerStateObserver {
        
    
    func deviceDisconnected(_ identifier: PolarBleSdk.PolarDeviceInfo, pairingError: Bool) {
        DispatchQueue.main.async { self.isConnected = false }
        // Reset streaming flags on disconnect
        ecgStreamingStarted = false
        hrStreamingStarted = false
    }
    
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        print("Feature ready: \(feature) for device: \(identifier)")
        if feature == .feature_polar_online_streaming {
            if !hrStreamingStarted {
                startHrStreaming(deviceId: identifier)
                hrStreamingStarted = true
            }
            if !ecgStreamingStarted {
                startEcgStreaming(deviceId: identifier)
                ecgStreamingStarted = true
            }
            if (!accStreamingStarted) {
                startAccStreaming(deviceId: identifier)
                accStreamingStarted = true
            }
        }
    }
        
    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        print("Battery level received for \(identifier): \(batteryLevel)%")
    }
    
    func batteryChargingStatusReceived(_ identifier: String, chargingStatus: PolarBleSdk.BleBasClient.ChargeState) {
        print("Battery charging status received for \(identifier): \(chargingStatus)")
    }
    
    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        print("DIS information received for \(identifier), UUID: \(uuid), value: \(value)")
    }
    
    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        print("DIS information received for \(identifier), key: \(key), value: \(value)")
    }
    
    func deviceConnecting(_ polarDeviceInfo: PolarDeviceInfo) {}
    func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
        DispatchQueue.main.async { self.isConnected = true }
    }

    func blePowerOn() {}
    func blePowerOff() {}
}

extension Notification.Name {
    static let didAppendECGSamples = Notification.Name("didAppendECGSamples")
}
