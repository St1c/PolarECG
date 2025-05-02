import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var bluetoothManager = BluetoothManager()
    @State private var isSharing = false
    @State private var shareFileURL: URL?
    @State private var canExport: Bool = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Modern background gradient
                LinearGradient(
                    gradient: Gradient(colors: [Color.black, Color(red: 0.1, green: 0.1, blue: 0.2)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                Group {
                    if bluetoothManager.isConnected {
                        VStack(spacing: 20) {
                            HStack {
                                Text("Polar H10 Monitor")
                                    .font(.largeTitle.bold())
                                    .foregroundColor(.white)
                                Spacer()
                                // Recording indicator
                                if bluetoothManager.isRecording {
                                    Label("REC", systemImage: "circle.fill")
                                        .foregroundColor(.red)
                                        .font(.headline)
                                        .padding(.trailing, 8)
                                }
                            }
                            .padding(.horizontal)
                            
                            HStack(spacing: 24) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Heart Rate")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Text("\(bluetoothManager.heartRate) BPM")
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("HRV (RMSSD)")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Text("\(bluetoothManager.hrv, specifier: "%.1f") ms")
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                            
                            // Robust HRV calculation info
                            if !bluetoothManager.robustHRVReady {
                                ProgressView(value: bluetoothManager.robustHRVProgress)
                                    .progressViewStyle(LinearProgressViewStyle(tint: .green))
                                    .padding(.horizontal)
                                Text("Robust HRV calculation in progress (\(Int(bluetoothManager.robustHRVProgress * 100))%)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            } else if let robust = bluetoothManager.robustHRVResult {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Robust HRV (5 min):")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                    HStack {
                                        Text("RMSSD: \(robust.rmssd, specifier: "%.1f") ms")
                                        Text("SDNN: \(robust.sdnn, specifier: "%.1f") ms")
                                        Text("Mean HR: \(robust.meanHR, specifier: "%.1f") BPM")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    HStack {
                                        Text("NN50: \(robust.nn50)")
                                        Text("pNN50: \(robust.pnn50, specifier: "%.1f") %")
                                        Text("Beats: \(robust.rrCount + 1)")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.white)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(8)
                            }
                            
                            ECGGraphView(
                                data: bluetoothManager.ecgData,
                                samplingRate: bluetoothManager.samplingRate,
                                peakIndices: bluetoothManager.last5sPeakIndices
                            )
                            .frame(height: 200)
                            .padding(.horizontal)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            
                            HStack(spacing: 16) {
                                if !bluetoothManager.isRecording {
                                    Button(action: {
                                        bluetoothManager.startRecording()
                                        // Reset export state when starting a new recording
                                        shareFileURL = nil
                                        canExport = false
                                    }) {
                                        Label("Start Recording", systemImage: "record.circle")
                                            .font(.headline)
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 18)
                                            .background(Color.green.opacity(0.2))
                                            .foregroundColor(.green)
                                            .cornerRadius(8)
                                    }
                                } else {
                                    Button(action: {
                                        bluetoothManager.stopRecording()
                                        // Try to export immediately after stopping recording
                                        let url = bluetoothManager.exportECGDataToFile()
                                        shareFileURL = url
                                        canExport = (url != nil)
                                    }) {
                                        Label("Stop Recording", systemImage: "stop.circle")
                                            .font(.headline)
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 18)
                                            .background(Color.red.opacity(0.2))
                                            .foregroundColor(.red)
                                            .cornerRadius(8)
                                    }
                                }
                                
                                Button(action: {
                                    if let url = bluetoothManager.exportECGDataToFile() {
                                        shareFileURL = url
                                        canExport = true
                                        isSharing = true
                                    } else {
                                        canExport = false
                                    }
                                }) {
                                    Label("Export & Share ECG", systemImage: "square.and.arrow.up")
                                        .font(.headline)
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 18)
                                        .background(canExport ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                                        .foregroundColor(canExport ? .blue : .gray)
                                        .cornerRadius(8)
                                }
                                .disabled(!canExport)
                            }
                            .padding(.top, 8)
                            .onAppear {
                                // Export is only possible if a file is available (after recording)
                                canExport = shareFileURL != nil
                            }
                            .onChange(of: shareFileURL) { newURL in
                                canExport = newURL != nil
                            }
                        }
                        .padding(.vertical)
                    } else {
                        DeviceSelectionView(bluetoothManager: bluetoothManager)
                            .padding(.top, 40)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isSharing) {
            if let url = shareFileURL {
                ActivityView(activityItems: [url], applicationActivities: nil)
            }
        }
    }
}

