//
//  ActivityView.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import SwiftUI
import UIKit

// Add this struct if it doesn't already exist in your project
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(
            activityItems: activityItems, 
            applicationActivities: applicationActivities
        )
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
