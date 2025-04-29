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
                        ECGGraphView(data: bluetoothManager.ecgData.suffix( Int(bluetoothManager.samplingRate * 10) ).map { $0 })
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

