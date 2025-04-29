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
        let exportData: [String: Any] = [
            "samplingRate": samplingRate,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "ecg": ecgData
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
    
    /// Computes RMSSD (ms) over the last 20 s of ECG
    var hrv: Double {
        let windowData = Array(ecgData.suffix(bufferSize))
        let rr = PeakDetector().detectRRIntervals(from: windowData)
        return HRVCalculator.computeRMSSD(from: rr)
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
