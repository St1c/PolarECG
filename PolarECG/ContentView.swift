import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var bluetoothManager = BluetoothManager()
    @State private var isSharing = false
    @State private var shareFileURL: URL?
    
    var body: some View {
        NavigationView {
            Group {
                if bluetoothManager.isConnected {
                    VStack(spacing: 16) {
                        Text("Heart Rate: \(bluetoothManager.heartRate) BPM")
                            .font(.title2)
                        Text("HRV (RMSSD): \(bluetoothManager.hrv, specifier: "%.1f") ms")
                            .font(.headline)
                        // Robust HRV calculation info
                        if !bluetoothManager.robustHRVReady {
                            ProgressView(value: bluetoothManager.robustHRVProgress)
                                .padding(.horizontal)
                            Text("Robust HRV calculation in progress (\(Int(bluetoothManager.robustHRVProgress * 100))%)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        } else if let robust = bluetoothManager.robustHRVResult {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Robust HRV (5 min):")
                                    .font(.subheadline)
                                Text("RMSSD: \(robust.rmssd, specifier: "%.1f") ms")
                                Text("SDNN: \(robust.sdnn, specifier: "%.1f") ms")
                                Text("Mean HR: \(robust.meanHR, specifier: "%.1f") BPM")
                                Text("NN50: \(robust.nn50)")
                                Text("pNN50: \(robust.pnn50, specifier: "%.1f") %")
                                Text("Beats: \(robust.rrCount + 1)")
                            }
                            .font(.caption)
                            .padding(.horizontal)
                        }
                        ECGGraphView(
                            data: bluetoothManager.ecgData,
                            samplingRate: bluetoothManager.samplingRate,
                            peakIndices: bluetoothManager.last5sPeakIndices
                        )
                        .frame(height: 200)
                        .padding(.horizontal)
                        Button("Export & Share ECG") {
                            if let url = bluetoothManager.exportECGDataToFile() {
                                shareFileURL = url
                                isSharing = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top)
                } else {
                    DeviceSelectionView(bluetoothManager: bluetoothManager)
                }
            }
            .navigationTitle("Polar H10 Monitor")
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isSharing) {
            if let url = shareFileURL {
                ActivityView(activityItems: [url], applicationActivities: nil)
            }
        }
    }
}

