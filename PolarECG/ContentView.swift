import SwiftUI
import UIKit

struct ContentView: View {
    // StateObject for the bluetooth manager
    @StateObject private var bluetoothManager = BluetoothManager()
    
    // Selected tab state
    @State private var selectedTab = 0
    
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
                
                if bluetoothManager.isConnected {
                    VStack(spacing: 0) {
                        // Custom tab switcher
                        HStack(spacing: 0) {
                            TabButton(
                                title: "ECG & HRV",
                                systemImage: "waveform.path.ecg",
                                isSelected: selectedTab == 0,
                                action: { selectedTab = 0 }
                            )
                            
                            TabButton(
                                title: "Jump Test",
                                systemImage: "figure.jumprope",
                                isSelected: selectedTab == 1,
                                action: { selectedTab = 1 }
                            )
                        }
                        .padding(.top, 10)
                        .background(Color.black.opacity(0.2))
                        
                        // Content view based on selected tab
                        if selectedTab == 0 {
                            HRVMeasurementView(bluetoothManager: bluetoothManager)
                        } else {
                            JumpMeasurementView(bluetoothManager: bluetoothManager)
                        }
                    }
                } else {
                    DeviceSelectionView(bluetoothManager: bluetoothManager)
                        .padding(.top, 40)
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
    }
}

// Custom tab button
struct TabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: isSelected ? 22 : 20))
                Text(title)
                    .font(.system(size: isSelected ? 12 : 11))
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .foregroundColor(isSelected ? .white : .gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isSelected ?
                    LinearGradient(
                        gradient: Gradient(colors: [Color.blue.opacity(0.7), Color.purple.opacity(0.7)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    ) : LinearGradient(
                        gradient: Gradient(colors: [Color.clear, Color.clear]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
            )
            .cornerRadius(4)
        }
    }
}

