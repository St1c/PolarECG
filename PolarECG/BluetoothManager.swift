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

    // MARK: - Published Data
    @Published var discoveredDevices: [PolarDeviceInfo] = []
    @Published var isConnected: Bool = false
    @Published var heartRate: Int = 0
    @Published var ecgData: [Double] = []
    @Published var last5sPeakIndices: [Int] = [] // no longer updated, kept for UI compatibility
    @Published var hrv: Double = 0.0

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
        api.searchForDevice()
            .subscribe(onNext: { [weak self] deviceInfo in
                guard let self = self else { return }
                if !self.discoveredDevices.contains(where: { $0.deviceId == deviceInfo.deviceId }) {
                    self.discoveredDevices.append(deviceInfo)
                }
            }, onError: { error in
                print("Scan error:", error)
            }).disposed(by: disposeBag)
    }

    /// Connects to the selected device
    func connect(to deviceId: String) {
        try? api.connectToDevice(deviceId)
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
        if rrBuffer.count >= windowBeats {
            return Array(rrBuffer.suffix(windowBeats))
        }
        return []
    }

    /// Computes RMSSD (ms) over the last 20 s using Polar RR intervals
    var hrvRMSSD: Double {
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
            let rmssd = self.rrIntervals.count >= 10 ? HRVCalculator.computeRMSSD(from: self.rrIntervals) : 0.0
            DispatchQueue.main.async { self.hrv = rmssd }
        }
    }

    private func startHrStreaming(deviceId: String) {
        api.startHrStreaming(deviceId)
            .subscribe(onNext: { [weak self] hrData in
                guard let self = self else { return }
                // Only process the first sample per event, and log only once
                if let sample = hrData.first {
                    DispatchQueue.main.async {
                        self.heartRate = Int(sample.hr)
                        NSLog("HR    BPM: \(sample.hr) rrs: \(sample.rrsMs) rrAvailable: \(sample.rrAvailable) contact status: \(sample.contactStatus) contact supported: \(sample.contactStatusSupported)")

                        // --- Only use RR intervals if rrAvailable is true ---
                        if sample.rrAvailable {
                            let newRRs = sample.rrsMs.map { Double($0) / 1000.0 }
                            self.rrBuffer.append(contentsOf: newRRs)
                            // Keep only the last robustRRBufferSize RR intervals for robust HRV
                            if self.rrBuffer.count > self.robustRRBufferSize {
                                self.rrBuffer.removeFirst(self.rrBuffer.count - self.robustRRBufferSize)
                            }
                        }
                    }
                }
            }, onError: { error in
                print("HR streaming error:", error)
            })
            .disposed(by: disposeBag)
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
        print("Recording stopped")
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
