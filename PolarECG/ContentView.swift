import SwiftUI
import UIKit

// Break down the complex property expressions into simpler components
struct ContentView: View {
    // StateObject for the bluetooth manager
    @StateObject private var bluetoothManager = BluetoothManager()
    
    // Simple boolean states 
    @State private var isSharing = false
    @State private var canExport: Bool = false
    @State private var showAccGraph = false
    @State private var showJumpMode = false
    
    // URL state - separating this from the complex expression
    @State private var shareFileURL: URL? = nil
    
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
                            
                            // Replace the HR/HRV display section with both Polar and Local HRV values
                            HStack(spacing: 24) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Heart Rate (Polar RR)")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    // Use the immediate integer heartRate property
                                    Text("\(bluetoothManager.heartRate) BPM")
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                    Text("HRV (RMSSD, Polar RR)")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                    Text("\(bluetoothManager.hrvRMSSD, specifier: "%.1f") ms")
                                        .font(.title3.bold())
                                        .foregroundColor(.green)
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                            
                            // Toggle for acceleration/vertical speed graph
                            Toggle(isOn: $showAccGraph) {
                                Text("Show Vertical Speed Graph")
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal)
                            .padding(.top, 4)

                            if showAccGraph {
                                VStack(spacing: 8) {
                                    HStack {
                                        Spacer()
                                        
                                        // Jump test mode toggle - only control we need
                                        Toggle(isOn: $showJumpMode) {
                                            Text("Jump Height Test")
                                                .foregroundColor(.yellow)
                                                .font(.headline)
                                        }
                                        .onChange(of: showJumpMode) { newValue in
                                            bluetoothManager.jumpMode = newValue
                                            if newValue {
                                                // Auto-test when turning on
                                                bluetoothManager.testJumpDetection()
                                            }
                                        }
                                        .toggleStyle(SwitchToggleStyle(tint: .yellow))
                                    }
                                    .padding(.horizontal, 8)
                                    
                                    // Jump mode info and test button
                                    if showJumpMode {
                                        Text("JUMP MODE: Stand still, then jump vertically")
                                            .font(.headline)
                                            .foregroundColor(.yellow)
                                            .padding(.horizontal, 8)
                                            
                                        // Jump test button
                                        Button(action: {
                                            bluetoothManager.testJumpDetection()
                                        }) {
                                            Label("Test + Detect Jumps", systemImage: "arrow.up.circle")
                                                .foregroundColor(.yellow)
                                                .font(.headline)
                                                .padding(.vertical, 8)
                                                .padding(.horizontal, 16)
                                                .background(Color.yellow.opacity(0.2))
                                                .cornerRadius(8)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        
                                        // Add real-time z-acceleration display
                                        Text("Z Acceleration: \(bluetoothManager.currentZAcceleration, specifier: "%.3f")g")
                                            .font(.subheadline)
                                            .foregroundColor(.yellow)
                                            .padding(.horizontal, 8)
                                    }
                                    
                                    // Inside the conditional block for when showJumpMode is true
                                    if showJumpMode {
                                        // Show jump mode instructions and debug information
                                        VStack(alignment: .leading) {
                                            Text("JUMP MODE: Perform a vertical jump with H10 sensor")
                                                .font(.headline)
                                                .foregroundColor(.yellow)

                                            // Add more debug info
                                            Text("Current Z: \(bluetoothManager.currentZAcceleration, specifier: "%.3f")g")
                                                .font(.subheadline)
                                                .foregroundColor(.yellow)
                                                
                                            HStack {
                                                // Make test button more prominent
                                                Button(action: {
                                                    print("Manually triggering test jump...")
                                                    bluetoothManager.testJumpDetection()
                                                }) {
                                                    Label("CREATE TEST JUMP", systemImage: "waveform.path.ecg")
                                                        .foregroundColor(.black)
                                                        .font(.headline.bold())
                                                        .padding(.vertical, 10)
                                                        .padding(.horizontal, 16)
                                                        .background(Color.yellow)
                                                        .cornerRadius(8)
                                                }
                                                
                                                // Add a detection button
                                                Button(action: {
                                                    print("Manual detection...")
                                                    bluetoothManager.detectJumps()
                                                }) {
                                                    Label("Detect Now", systemImage: "magnifyingglass")
                                                        .foregroundColor(.yellow)
                                                        .padding(.vertical, 10)
                                                        .padding(.horizontal, 16)
                                                        .background(Color.black.opacity(0.3))
                                                        .cornerRadius(8)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                    }

                                    // Display graph - always pass empty array for peaks to hide them
                                    // Only show the last 15s of data for jump mode (750 samples at 50Hz) 
                                    VerticalSpeedGraphView(
                                        verticalSpeedData: bluetoothManager.verticalSpeedData,
                                        zData: showJumpMode ? 
                                            bluetoothManager.accelerationData.suffix(750).map { ($0.timestamp, $0.z) } :
                                            bluetoothManager.accelerationData.suffix(3000).map { ($0.timestamp, $0.z) },
                                        peaks: [], // Always empty - don't show peaks
                                        jumpEvents: showJumpMode ? bluetoothManager.jumpEvents : [],
                                        jumpHeights: showJumpMode ? bluetoothManager.jumpHeights : []
                                    )
                                    .frame(height: 180)
                                    .padding(.horizontal)
                                    
                                    // Jump heights display - the only info we need now
                                    if showJumpMode && !bluetoothManager.jumpHeights.isEmpty {
                                        // Format heights with 1 decimal place, sort from highest to lowest
                                        let sortedHeights = bluetoothManager.jumpHeights.sorted(by: >)
                                        
                                        VStack(alignment: .leading) {
                                            Text("Jump Heights:")
                                                .font(.headline)
                                                .foregroundColor(.yellow)
                                            
                                            // Show the max height with larger text
                                            if let max = sortedHeights.first {
                                                Text("Highest: \(String(format: "%.1f", max)) cm")
                                                    .font(.title)
                                                    .foregroundColor(.yellow)
                                                    .bold()
                                            }
                                            
                                            // List all jumps
                                            Text("All jumps: " + sortedHeights.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " cm")
                                                .font(.subheadline)
                                                .foregroundColor(.yellow)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.black.opacity(0.3))
                                        .cornerRadius(8)
                                        .padding(.horizontal, 8)
                                    } else if showJumpMode {
                                        Text("No jumps detected yet. Try the 'Generate Test Jump' button or perform a real jump.")
                                            .font(.subheadline)
                                            .foregroundColor(.yellow)
                                            .padding(.horizontal, 8)
                                    }
                                    
                                    // Add a button to manually trigger jump detection
                                    Button(action: {
                                        print("Manual jump detection triggered")
                                        bluetoothManager.detectJumps() // Directly call jump detection
                                    }) {
                                        Text("Detect Jumps Now")
                                            .foregroundColor(.yellow)
                                            .padding(.vertical, 4)
                                            .padding(.horizontal, 8)
                                            .background(Color.yellow.opacity(0.2))
                                            .cornerRadius(5)
                                    }
                                    .padding(.horizontal, 8)
                                }
                            }

                            // Robust HRV calculation info
                            if !bluetoothManager.robustHRVReady {
                                ProgressView(value: bluetoothManager.robustHRVProgress)
                                    .progressViewStyle(LinearProgressViewStyle(tint: .green))
                                    .padding(.horizontal)
                                Text("Robust HRV calculation in progress (\(Int(bluetoothManager.robustHRVProgress * 100))%)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            } else {
                                HStack(alignment: .top, spacing: 24) {
                                    // --- Polar RR robust HRV ---
                                    if let robust = bluetoothManager.robustHRVResult {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Robust HRV (Polar RR, 2 min):")
                                                .font(.subheadline)
                                                .foregroundColor(.green)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("RMSSD: \(robust.rmssd, specifier: "%.1f") ms")
                                                Text("SDNN: \(robust.sdnn, specifier: "%.1f") ms")
                                                Text("Mean HR: \(robust.meanHR, specifier: "%.1f") BPM")
                                                Text("NN50: \(robust.nn50)")
                                                Text("pNN50: \(robust.pnn50, specifier: "%.1f") %")
                                                Text("Beats: \(robust.rrCount + 1)")
                                            }
                                            .font(.caption)
                                            .foregroundColor(.green)
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 10)
                                        .background(Color.green.opacity(0.08))
                                        .cornerRadius(8)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                            
                            Spacer()
                            
                            // --- Start/Stop Recording Button Row ---
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
                            }
                            .padding(.top, 8)

                            // --- Export Buttons Row ---
                            HStack(spacing: 16) {
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
                                
                                Button(action: {
                                    if let url = ECGGraphExporter.exportECGGraph(
                                        data: bluetoothManager.ecgData,
                                        samplingRate: bluetoothManager.samplingRate,
                                        peakIndices: bluetoothManager.last5sPeakIndices // or all peaks if available
                                    ) {
                                        shareFileURL = url
                                        canExport = true
                                        isSharing = true
                                    } else {
                                        canExport = false
                                    }
                                }) {
                                    Label("Export ECG Graph", systemImage: "photo.on.rectangle")
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
                        .padding(.vertical, 0)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 24)
                        .padding(.horizontal, 0)
                        .background(Color.clear)
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

