//
//  ActivityView.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import SwiftUI
import UIKit

// Add this struct if it doesn't already exist in your project
// Helper view for sharing files
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

