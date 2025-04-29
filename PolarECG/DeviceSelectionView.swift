//
//  DeviceSelectionView.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import SwiftUI
import PolarBleSdk

struct DeviceSelectionView: View {
    @ObservedObject var bluetoothManager: BluetoothManager

    var body: some View {
        VStack {
            Text("Select Polar Device")
                .font(.headline)
                .padding(.top)
            List(bluetoothManager.discoveredDevices, id: \.deviceId) { device in
                Button {
                    bluetoothManager.connect(to: device.deviceId)
                } label: {
                    Text(device.deviceId)
                        .foregroundColor(.primary)
                }
            }
            .listStyle(PlainListStyle())

            Button("Scan for Devices") {
                bluetoothManager.startScan()
            }
            .padding()
        }
    }
}
