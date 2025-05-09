//
//  PolarECGApp.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//

import SwiftUI

@main
struct PolarECGApp: App {
    // Use an environment object to access BluetoothManager from anywhere
    @StateObject private var bluetoothManager = BluetoothManager()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetoothManager)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                // App is entering background
                bluetoothManager.performAppTerminationCleanup()
            }
        }
    }
}
