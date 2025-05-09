import SwiftUI

struct JumpMeasurementView: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    
    // Jump mode is automatically enabled when this view appears
    @State private var jumpTestResults: [Double] = []
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Jump Height Test")
                    .font(.largeTitle.bold())
                    .foregroundColor(.yellow)
                Spacer()
                
                // Show the current heart rate as a small indicator
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                    Text("\(bluetoothManager.heartRate)")
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.3))
                .cornerRadius(12)
            }
            .padding(.horizontal)
            
            // Instructions
            Text("Stand still, then jump vertically.\nThe sensor will measure your jump height.")
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.vertical, 4)
            
            // Current acceleration reading
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Z Acceleration:")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(bluetoothManager.currentZAcceleration, specifier: "%.3f") g")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // Display the threshold when useful
                if bluetoothManager.currentThreshold > 0 {
                    VStack(alignment: .trailing) {
                        Text("Threshold:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("\(bluetoothManager.currentThreshold, specifier: "%.3f") g")
                            .font(.body)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal)
            
            // Display graph - always in jump mode
            // Break complex expression into steps to help compiler
            let limitedAccData = bluetoothManager.accelerationData.suffix(750)
            let zData = limitedAccData.map { ($0.timestamp, $0.z) }
            
            VerticalSpeedGraphView(
                verticalSpeedData: bluetoothManager.verticalSpeedData,
                zData: zData,
                peaks: [], // Always empty - don't show peaks
                jumpEvents: bluetoothManager.jumpEvents,
                jumpHeights: bluetoothManager.jumpHeights
            )
            .frame(height: 220)
            .padding(.horizontal)
            
            // Jump heights display
            if !bluetoothManager.jumpHeights.isEmpty {
                JumpHeightsView(jumpHeights: bluetoothManager.jumpHeights, jumpTestResults: jumpTestResults)
            } else {
                Text("No jumps detected yet. Jump in place and tap 'Detect Jumps'.")
                    .font(.subheadline)
                    .foregroundColor(.yellow)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // Break up the control buttons section
            JumpControlButtons(
                bluetoothManager: bluetoothManager,
                jumpTestResults: $jumpTestResults
            )
            .padding(.horizontal)
        }
        .padding(.vertical)
        .onAppear {
            // Enable jump mode when this view appears
            bluetoothManager.jumpMode = true
            // Generate a test jump for better UX
            // bluetoothManager.testJumpDetection() // Fixed: removed $ and added parentheses
        }
        .onDisappear {
            // Disable jump mode when leaving this view
            bluetoothManager.jumpMode = false
        }
    }
}

// Extract the jump heights view to a separate component
struct JumpHeightsView: View {
    let jumpHeights: [Double]
    let jumpTestResults: [Double]
    
    var body: some View {
        // Format heights with 1 decimal place, sort from highest to lowest
        let sortedHeights = jumpHeights.sorted(by: >)
        
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
                
            if jumpTestResults.count > 0 {
                Text("Session best: \(String(format: "%.1f", jumpTestResults.max() ?? 0)) cm")
                    .font(.body)
                    .foregroundColor(.green)
                    .padding(.top, 4)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.3))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

// Extract control buttons to a separate component
struct JumpControlButtons: View {
    let bluetoothManager: BluetoothManager
    @Binding var jumpTestResults: [Double]
    
    var body: some View {
        VStack(spacing: 16) {
            // Manual detection button
            Button(action: {
                bluetoothManager.detectJumps()
                
                // Add to test results if we have new heights
                if let newHeight = bluetoothManager.jumpHeights.max() {
                    jumpTestResults.append(newHeight)
                }
            }) {
                Label("Detect Jump", systemImage: "magnifyingglass.circle.fill")
                    .font(.headline)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity)
                    .background(Color.yellow)
                    .foregroundColor(.black)
                    .cornerRadius(12)
            }
            
            // Clear/Reset button
            Button(action: {
                // bluetoothManager.testJumpDetection() // Fixed: no changes needed here
            }) {
                Label("Reset & Test", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.3))
                    .foregroundColor(.orange)
                    .cornerRadius(12)
            }
            
            // Save session results button
            Button(action: {
                // Save this session's best jumps
                if let max = jumpTestResults.max() {
                    let defaults = UserDefaults.standard
                    var savedJumps = defaults.array(forKey: "savedJumpHeights") as? [Double] ?? []
                    savedJumps.append(max)
                    defaults.set(savedJumps, forKey: "savedJumpHeights")
                }
            }) {
                Label("Save Best Jump", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.3))
                    .foregroundColor(.green)
                    .cornerRadius(12)
            }
            .disabled(jumpTestResults.isEmpty)
        }
    }
}
