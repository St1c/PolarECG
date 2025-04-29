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

class BluetoothManager: NSObject, ObservableObject {
    
    // MARK: - API & Resources
    private var api: PolarBleApi!
    private let disposeBag = DisposeBag()
    private var ecgStreamingStarted = false

    // MARK: - Published Data
    @Published var discoveredDevices: [PolarDeviceInfo] = []
    @Published var isConnected: Bool = false
    @Published var heartRate: Int = 0
    @Published var ecgData: [Double] = []

    // MARK: - Buffer Settings
    let samplingRate = 130.0
    private let hrvWindow = 20.0           // seconds
    private var bufferSize: Int { Int(samplingRate * hrvWindow) }

    // MARK: - Robust HRV Calculation State
    @Published var robustHRVReady: Bool = false
    @Published var robustHRVProgress: Double = 0.0 // 0.0 ... 1.0
    @Published var robustHRVResult: RobustHRVResult? = nil

    private let robustWindow: Double = 300.0 // 5 minutes
    private var robustBufferSize: Int { Int(samplingRate * robustWindow) }
    private var robustHRVCalculationTask: Task<Void, Never>? = nil

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
    }

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
            let progress = min(Double(self.ecgData.count) / Double(self.robustBufferSize), 1.0)
            self.robustHRVProgress = progress
            if progress < 1.0 {
                self.robustHRVReady = false
            }
            // --- DEBUG: Print progress for troubleshooting ---
            print("Robust HRV progress: \(progress) (\(self.ecgData.count)/\(self.robustBufferSize))")
        }
        // Ensure timer runs on main run loop
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

        ecgData.append(contentsOf: smoothed)

        // Keep rolling buffer of 2×HRV window
        let maxCount = bufferSize * 2
        if ecgData.count > maxCount {
            ecgData.removeFirst(ecgData.count - maxCount)
        }
        // --- DEBUG: Print buffer size for troubleshooting robust HRV progress ---
        print("ECG buffer count: \(ecgData.count), robustBufferSize: \(robustBufferSize), progress: \(Double(ecgData.count) / Double(robustBufferSize))")
        NotificationCenter.default.post(name: .didAppendECGSamples, object: nil)
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
        // --- HRV per second (using 20s window, logged every second after first 20s) ---
        let hrvPerSecond: [[String: Any]] = computeHRVPerSecondSlidingWindow()

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

        let exportData: [String: Any] = [
            "samplingRate": samplingRate,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "ecg": ecgData,
            "hrvPerSecond": hrvPerSecond,
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
        let window = Int(samplingRate * hrvWindow)
        guard window > 0, ecgData.count >= window else { return [] }
        let totalSeconds = Int(Double(ecgData.count - window) / samplingRate)
        var result: [[String: Any]] = []
        let startTime = Date().addingTimeInterval(-Double(ecgData.count) / samplingRate)
        for sec in 0..<totalSeconds {
            let endIdx = window + sec * Int(samplingRate)
            let startIdx = endIdx - window
            let windowData = Array(ecgData[startIdx..<endIdx])
            let rr = PeakDetector().detectRRIntervals(from: windowData)
            let rmssd = HRVCalculator.computeRMSSD(from: rr)
            let sdnn = HRVCalculator.computeSDNN(from: rr)
            let meanHR = HRVCalculator.computeMeanHR(from: rr)
            let timestamp = ISO8601DateFormatter().string(from: startTime.addingTimeInterval(Double(window + sec * Int(samplingRate)) / samplingRate))
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
        let window = Int(samplingRate * hrvWindow)
        let totalSeconds = Int(Double(ecgData.count) / samplingRate)
        guard window > 0, totalSeconds > 0 else { return [] }
        var result: [[String: Any]] = []
        for sec in 0..<totalSeconds {
            let endIdx = min(ecgData.count, (sec + 1) * Int(samplingRate))
            let startIdx = max(0, endIdx - window)
            let windowData = Array(ecgData[startIdx..<endIdx])
            let rr = PeakDetector().detectRRIntervals(from: windowData)
            let rmssd = HRVCalculator.computeRMSSD(from: rr)
            let sdnn = HRVCalculator.computeSDNN(from: rr)
            let meanHR = HRVCalculator.computeMeanHR(from: rr)
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
    
    /// RR intervals (s) over the last 20s window
    var rrIntervals: [Double] {
        let windowData = Array(ecgData.suffix(bufferSize))
        return PeakDetector().detectRRIntervals(from: windowData)
    }

    /// Computes RMSSD (ms) over the last 20 s of ECG
    var hrvRMSSD: Double {
        HRVCalculator.computeRMSSD(from: rrIntervals)
    }

    /// Computes SDNN (ms) over the last 20 s of ECG
    var hrvSDNN: Double {
        HRVCalculator.computeSDNN(from: rrIntervals)
    }

    /// Computes mean heart rate (BPM) over the last 20 s of ECG
    var meanHeartRate: Double {
        HRVCalculator.computeMeanHR(from: rrIntervals)
    }

    /// Computes RMSSD (ms) over the last 20 s of ECG
    var hrv: Double {
        let windowData = Array(ecgData.suffix(bufferSize))
        let rr = PeakDetector().detectRRIntervals(from: windowData)
        return HRVCalculator.computeRMSSD(from: rr)
    }
    
    /// Indices of detected peaks in the last 5s window, relative to ecgData
    var last5sPeakIndices: [Int] {
        let windowCount = Int(samplingRate * 5)
        guard ecgData.count >= 3 else { return [] }
        let offset = ecgData.count > windowCount ? ecgData.count - windowCount : 0
        let windowData = Array(ecgData.suffix(windowCount))
        let peaks = PeakDetector().detectPeakIndices(from: windowData)
        return peaks.map { $0 + offset }
    }
    
    private func startHrStreaming(deviceId: String) {
        api.startHrStreaming(deviceId)
            .subscribe(onNext: { hrData in
                DispatchQueue.main.async {
                    if let sample = hrData.first {
                        self.heartRate = Int(sample.hr)
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

        robustHRVCalculationTask = Task.detached { [weak self] in
            guard let self = self else { return }
            while true {
                if self.ecgData.count < self.robustBufferSize {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                    continue
                }
                // Compute robust HRV metrics
                let windowData = Array(self.ecgData.suffix(self.robustBufferSize))
                let rr = PeakDetector(adaptive: true).detectRRIntervals(from: windowData)
                let rmssd = HRVCalculator.computeRMSSD(from: rr)
                let sdnn = HRVCalculator.computeSDNN(from: rr)
                let meanHR = HRVCalculator.computeMeanHR(from: rr)
                let nn50 = HRVCalculator.computeNN50(from: rr)
                let pnn50 = HRVCalculator.computePNN50(from: rr)
                let result = RobustHRVResult(
                    rmssd: rmssd,
                    sdnn: sdnn,
                    meanHR: meanHR,
                    nn50: nn50,
                    pnn50: pnn50,
                    rrCount: rr.count
                )
                await MainActor.run {
                    self.robustHRVResult = result
                    self.robustHRVReady = true
                    self.robustHRVProgress = 1.0
                }
                // Update every 10s
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
}

// MARK: - Polar SDK Observers

extension BluetoothManager: PolarBleApiObserver, PolarBleApiDeviceInfoObserver, PolarBleApiDeviceFeaturesObserver, PolarBleApiPowerStateObserver {
        
    
    func deviceDisconnected(_ identifier: PolarBleSdk.PolarDeviceInfo, pairingError: Bool) {
        DispatchQueue.main.async { self.isConnected = false }
    }
    
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        print("Feature ready: \(feature) for device: \(identifier)")
        if feature == .feature_polar_online_streaming && !ecgStreamingStarted {
            startHrStreaming(deviceId: identifier)
            ecgStreamingStarted = true
            startEcgStreaming(deviceId: identifier)
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
