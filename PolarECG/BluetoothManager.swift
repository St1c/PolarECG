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
        
        // Use throttled processing for ECG data to reduce CPU load
        setupECGProcessing()
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
            
            // Reduce UI updates by batching data changes
            // and only publishing changes when we have enough new data
            let currentCount = self.ecgData.count
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
            
            // Throttle UI updates by only notifying observers when we have significant changes
            // This reduces the number of redraws triggered
            if self.ecgData.count - currentCount >= Int(self.samplingRate / 10) { // ~10 times per second max
                NotificationCenter.default.post(name: .didAppendECGSamples, object: nil)
            }
        }
    }

    private func setupECGProcessing() {
        $ecgData
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
            .sink { [weak self] _ in
                self?.processECGDataAsync()
            }
            .store(in: &cancellables)
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
                    
                    // Store current values in UserDefaults for sharing between views
                    UserDefaults.standard.set(meanHR, forKey: "currentHR")
                    UserDefaults.standard.set(rmssd, forKey: "currentHRV")
                }
            }
        }
        // ...existing code...
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

    func exportECGDataToFile() -> URL? {
        // Use the archived session data if available, otherwise use current data
        let exportData: [String: Any]
        
        if let archived = archivedSessionData {
            exportData = archived
        } else {
            // No archived data, use current buffers (live data)
            let ecgExport = Array(ecgData.suffix(rawECGBufferSize))
            
            // Ensure computedPerSecond is up-to-date
            self.updateComputedPerSecond()
            
            // Create robust HRV summary if available
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
            
            exportData = [
                "samplingRate": samplingRate,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "ecg": ecgExport,
                "hrvPerSecond": computedPerSecond,
                "robustHRVSummary": robustSummary as Any
            ]
        }
        
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

    var rrIntervals: [Double] {
        let windowBeats = Int(hrvWindow * 2)
        // Always return up to the last 20 RR intervals, even if fewer are available
        if rrBuffer.count > 0 {
            return Array(rrBuffer.suffix(min(windowBeats, rrBuffer.count)))
        }
        return []
    }

    var hrvRMSSD: Double {
        // Show HRV even if fewer than 20 samples are available
        HRVCalculator.computeRMSSD(from: rrIntervals)
    }

    var hrvSDNN: Double {
        HRVCalculator.computeSDNN(from: rrIntervals)
    }

    var meanHeartRate: Double {
        HRVCalculator.computeMeanHR(from: rrIntervals)
    }

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
        // Find peaks above threshold, min interval 0.3s (reduced from 0.5s)
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
            let prev = recent[i-1]
            let curr = recent[i]
            let next = recent[i+1]
            // Detect both positive and negative peaks (abs difference from mean)
            let absFromMean = abs(curr.z - mean)
            // Use absolute value criteria rather than just being above threshold
            if absFromMean > abs(threshold - mean) && 
               abs(curr.z) > abs(prev.z) && abs(curr.z) > abs(next.z) && 
               (curr.timestamp - lastPeak) > 300 { // 300ms minimum interval
                newPeaks.append((timestamp: curr.timestamp, value: curr.z))
                lastPeak = curr.timestamp
                print("Peak detected at \(curr.timestamp) with value \(curr.z), abs from mean: \(absFromMean)")
            }
        }
        // Only keep last 1 minute of peaks, but ensure we have at least new peaks
        let combinedPeaks = lastMinutePeaks + newPeaks
        detectedPeaks = Array(combinedPeaks.suffix(max(20, newPeaks.count)))
        var intervals: [Double] = []
        peakIntervals = intervals
        
        // Compute intervals
        let sortedTimestamps = detectedPeaks.map { $0.timestamp / 1000.0 }.sorted()
        
        for i in 1..<sortedTimestamps.count {
            intervals.append(sortedTimestamps[i] - sortedTimestamps[i-1])
        }
        peakIntervals = intervals
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

    // Improved jump detection with physics-based approach
    func detectJumps() {
        guard jumpMode else { return }
        // Clear previous results each time
        jumpEvents = []
        jumpHeights = []
        
        // Look at the last 10 seconds of data
        let fs = accSamplingRate
        let rawSamples = accelerationData.suffix(Int(10.0 * fs))
        guard rawSamples.count > 20 else {
            print("Not enough acceleration samples for jump detection")
            return
        }
        
        // Get Z values
        let zValues = rawSamples.map { $0.z }
        // Update current Z value
        if let lastSample = rawSamples.last {
            currentZAcceleration = lastSample.z
        }
        
        // Step 1: Apply high-pass filter to remove gravity bias (0.5 Hz cutoff)
        let filteredZ = highPass(zValues, cutoffHz: 0.5, sampleRate: fs)
        
        // Step 2: Smooth the signal to reduce noise (3-point moving average)
        let smoothedZ = movingAverage(filteredZ, windowSize: 3)
        
        // Step 3: Compute signal statistics for adaptive thresholds
        let mean = smoothedZ.reduce(0, +) / Double(smoothedZ.count)
        let absValues = smoothedZ.map { abs($0 - mean) }
        let stdDev = sqrt(absValues.map { pow($0, 2) }.reduce(0, +) / Double(absValues.count))
        
        // Step 4: Define detection thresholds (more sensitive)
        let takeoffThreshold = -0.6 // Negative peak for takeoff (pushing down)
        let landingThreshold = 1.0  // Positive peak for landing
        let minFlightTime = 0.15    // Minimum flight time in seconds
        let maxFlightTime = 1.0     // Maximum flight time in seconds
        
        // Step 5: Scan for jump phases - takeoff followed by landing
        var jumpCandidates = [(takeoffIdx: Int, landingIdx: Int, flightTime: Double, heightCm: Double)]()
        
        var takeoffCandidates = [Int]()
        var inFlight = false
        var takeoffIdx = -1
        
        // Find potential takeoff points (significant negative acceleration)
        for i in 1..<(smoothedZ.count-1) {
            // Current point and neighbors
            let prev = smoothedZ[i-1]
            let curr = smoothedZ[i]
            let next = smoothedZ[i+1]
            
            // Detect takeoff - negative peak (pushing down)
            if !inFlight && curr < takeoffThreshold && curr < prev && curr < next {
                takeoffCandidates.append(i)
                print("Potential takeoff at \(i): \(curr)")
            }
            
            // For each takeoff candidate, look for a landing within the valid time window
            if !inFlight && !takeoffCandidates.isEmpty {
                takeoffIdx = takeoffCandidates.removeLast() // Use most recent takeoff candidate
                inFlight = true
                print("Flight started at index \(takeoffIdx)")
            }
            
            // Detect landing after takeoff - positive peak
            if inFlight && curr > landingThreshold && curr > prev && curr > next {
                let landingIdx = i
                let flightTime = Double(landingIdx - takeoffIdx) / fs
                
                // Validate flight time
                if flightTime >= minFlightTime && flightTime <= maxFlightTime {
                    // Calculate height using physics formula: h = 1/8 × g × t²
                    // g = 9.81 m/s², t = flight time in seconds
                    let heightCm = 122.625 * pow(flightTime, 2) // 9.81/8*100*t²
                    
                    jumpCandidates.append(
                        (takeoffIdx: takeoffIdx, 
                         landingIdx: landingIdx, 
                         flightTime: flightTime,
                         heightCm: heightCm)
                    )
                    print("Jump detected! Takeoff: \(takeoffIdx), Landing: \(landingIdx), Flight: \(flightTime)s, Height: \(heightCm)cm")
                }
                
                inFlight = false
                takeoffIdx = -1
            }
            
            // Reset flight state if too much time passes without landing
            if inFlight && (i - takeoffIdx) > Int(maxFlightTime * fs) {
                inFlight = false
                takeoffIdx = -1
            }
        }
        
        // Step 6: Filter candidates to find the most likely jump
        if !jumpCandidates.isEmpty {
            // Sort by height (highest jump is most likely a real jump)
            let sortedJumps = jumpCandidates.sorted { $0.heightCm > $1.heightCm }
            
            // Convert to app's expected format
            jumpEvents = sortedJumps.map { 
                (takeoffIdx: $0.takeoffIdx, landingIdx: $0.landingIdx, heightCm: $0.heightCm) 
            }
            jumpHeights = sortedJumps.map { $0.heightCm }
            
            print("Found \(jumpCandidates.count) jumps, best height: \(jumpHeights.first ?? 0) cm")
        } else {
            // Fallback detection for subtle jumps
            fallbackJumpDetection(zValues: zValues, fs: fs)
        }
        
        objectWillChange.send()
    }
    
    // Fallback detection for more subtle jumps
    private func fallbackJumpDetection(zValues: [Double], fs: Double) {
        // Look for rapid changes in acceleration as indicators of takeoff and landing
        var crossings = [(index: Int, direction: Bool)]() // true = rising, false = falling
        
        let mean = zValues.reduce(0, +) / Double(zValues.count)
        
        // Find zero crossings (where acceleration crosses the mean)
        for i in 1..<zValues.count {
            if (zValues[i-1] < mean && zValues[i] >= mean) {
                crossings.append((index: i, direction: true)) // rising
            } else if (zValues[i-1] > mean && zValues[i] <= mean) {
                crossings.append((index: i, direction: false)) // falling
            }
        }
        
        // Need at least 2 crossings to detect a jump
        guard crossings.count >= 2 else { return }
        
        // Look for rising followed by falling with appropriate time gap
        for i in 0..<(crossings.count-1) {
            let first = crossings[i]
            let second = crossings[i+1]
            
            if first.direction == false && second.direction == true {
                let timeDiff = Double(second.index - first.index) / fs
                
                // Valid jump time range
                if timeDiff >= 0.15 && timeDiff <= 0.8 {
                    // More conservative height calculation for subtle jumps
                    let heightCm = 100.0 * pow(timeDiff, 2)
                    // Clamp to realistic range
                    let clampedHeight = min(max(heightCm, 5.0), 40.0)
                    
                    jumpEvents = [(takeoffIdx: first.index, landingIdx: second.index, heightCm: clampedHeight)]
                    jumpHeights = [clampedHeight]
                    print("SUBTLE JUMP DETECTED! Height: \(clampedHeight)cm, Flight time: \(timeDiff)s")
                    return
                }
            }
        }
    }
    
    // Helper function for moving average
    private func movingAverage(_ data: [Double], windowSize: Int) -> [Double] {
        guard data.count > windowSize, windowSize > 0 else { return data }
        
        var result = [Double]()
        for i in 0...(data.count - windowSize) {
            let windowSum = data[i..<(i+windowSize)].reduce(0, +)
            result.append(windowSum / Double(windowSize))
        }
        
        // Pad the end to maintain original length
        let padding = data.count - result.count
        if padding > 0 {
            result.append(contentsOf: Array(repeating: result.last ?? 0, count: padding))
        }
        
        return result
    }

    // private func movingAverage(_ input: [Double], windowSize: Int) -> [Double] {
    //     guard windowSize > 1, input.count >= windowSize else { return input }
    //     var result: [Double] = []
    //     for i in 0..<(input.count - windowSize + 1) {
    //         let window = input[i..<(i + windowSize)]
    //         result.append(window.reduce(0, +) / Double(windowSize))
    //     }
    //     // pad to keep length
    //     if let last = result.last {
    //         result.append(contentsOf: Array(repeating: last, count: input.count - result.count))
    //     }
    //     return result
    // }

    func startRobustHRVCalculation() {
        robustHRVCalculationTask?.cancel()
        robustHRVCalculationTask = nil
        robustHRVReady = false
        robustHRVProgress = 0.0
        robustHRVResult = nil
        // Removed robustHRVResultLocal
        // Force UI update
        objectWillChange.send()
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

    // Add a session archive to store data after recording stops
    private var archivedSessionData: [String: Any]? = nil
    private var lastRecordingTime: Date? = nil
    
    // MARK: - Recording Control
    
    func startRecording() {
        // Archive any previous session data before starting a new recording
        if isRecording {
            archiveCurrentSessionIfNeeded()
        }
        
        // Create (or replace) the session file
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent("ecg_session_\(Date().timeIntervalSince1970).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        sessionFileURL = fileURL
        sessionFileHandle = try? FileHandle(forWritingTo: fileURL)
        isRecording = true
        lastRecordingTime = Date()
        print("Recording started: \(fileURL.path)")
    }

    func stopRecording() {
        // Archive the session data before stopping
        archiveCurrentSessionIfNeeded()
        
        isRecording = false
        sessionFileHandle?.closeFile()
        sessionFileHandle = nil
        sessionFileURL = nil
        
        // Reset the streaming position counter
        lastStreamedSecond = 0
        
        print("Recording stopped - data preserved for export")
        
        // Clean up old log files
        cleanupOldLogFiles()
    }
    
    private func archiveCurrentSessionIfNeeded() {
        guard sessionFileURL != nil else { return }
        
        // Save a snapshot of current session data
        let ecgSnapshot = Array(ecgData.suffix(rawECGBufferSize))
        // Ensure computedPerSecond is up-to-date before archiving
        self.updateComputedPerSecond()
        let hrvSnapshot = Array(computedPerSecond)
        
        // Get robust HRV summary if available
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
        
        // Read all computed values from the session file
        var hrvPerSecond: [[String: Any]] = []
        if let sessionURL = sessionFileURL,
           let fileHandle = try? FileHandle(forReadingFrom: sessionURL) {
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
            fileHandle.closeFile()
        }
        
        // Create archive data structure
        archivedSessionData = [
            "samplingRate": samplingRate,
            "timestamp": ISO8601DateFormatter().string(from: lastRecordingTime ?? Date()),
            "ecg": ecgSnapshot,
            "hrvPerSecond": hrvSnapshot,
            "fileHRVData": hrvPerSecond,
            "robustHRVSummary": robustSummary as Any
        ]
    }

    // Accessor method for archived session data
    func getArchivedSessionData() -> [String: Any]? {
        return archivedSessionData
    }
    
    // MARK: - File Management
    
    /// Clean up old log files, keeping only recent ones
    private func cleanupOldLogFiles() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileManager = FileManager.default
        
        do {
            // Get all files in Documents
            let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.creationDateKey], options: [])
            
            // Filter for our log file types
            let sessionFiles = files.filter { $0.lastPathComponent.hasPrefix("ecg_session_") }
            let exportFiles = files.filter { $0.lastPathComponent.hasPrefix("ecg_export_") }
            let graphFiles = files.filter { $0.lastPathComponent.hasPrefix("ecg_graph_") }
            
            // Keep only the 5 most recent session files
            cleanupOldFiles(sessionFiles, keepCount: 5)
            // Keep only the 10 most recent export files
            cleanupOldFiles(exportFiles, keepCount: 10)
            // Keep only the 10 most recent graph files
            cleanupOldFiles(graphFiles, keepCount: 10)
            
        } catch {
            print("Error cleaning up files: \(error)")
        }
    }
    
    /// Delete old files, keeping only the most recent ones
    private func cleanupOldFiles(_ files: [URL], keepCount: Int) {
        guard files.count > keepCount else { return }
        
        // Sort by creation date, newest first
        let sortedFiles = files.sorted { (file1, file2) -> Bool in
            let date1 = try? file1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
            let date2 = try? file2.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
            return date1! > date2!
        }
        
        // Delete old files beyond our keep count
        for file in sortedFiles.suffix(from: keepCount) {
            try? FileManager.default.removeItem(at: file)
            print("Removed old file: \(file.lastPathComponent)")
        }
    }
    
    // MARK: - Auto Cleanup
    
    /// Call this in AppDelegate's applicationWillTerminate or SceneDelegate's sceneDidDisconnect
    func performAppTerminationCleanup() {
        // Stop any ongoing recording
        if isRecording {
            stopRecording()
        }
        
        // Clean up old log files
        cleanupOldLogFiles()
    }

    // ... existing code ...
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
