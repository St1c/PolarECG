//
//  ECGGraphView.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import SwiftUI

struct ECGGraphView: View {
    let data: [Double]
    let samplingRate: Double
    let peakIndices: [Int]?
    
    // Use State and Timer for smoother animations
    @State private var displayTime = Date()
    
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                // Only plot the last 5s window
                let windowCount = Int(samplingRate * 5)
                let plotData = data.suffix(windowCount)
                guard plotData.count > 1 else { return }
                let plotArray = Array(plotData)
                let amplitudeScale: CGFloat = 60 // larger = smaller amplitude
                let verticalMargin: CGFloat = size.height * 0.15
                let centerY = size.height / 2

                let path = Path { p in
                    let step = size.width / CGFloat(plotArray.count - 1)
                    p.move(to: CGPoint(x: 0, y: centerY))
                    for (i, v) in plotArray.enumerated() {
                        let x = CGFloat(i) * step
                        // scale & invert for display, add margin
                        let y = centerY - CGFloat(v) * amplitudeScale
                        let yClamped = min(max(y, verticalMargin), size.height - verticalMargin)
                        p.addLine(to: CGPoint(x: x, y: yClamped))
                    }
                }
                ctx.stroke(path, with: .color(.green), lineWidth: 1.5)

                // Draw peaks as red circles
                if let peakIndices = peakIndices {
                    let offset = data.count > windowCount ? data.count - windowCount : 0
                    for peak in peakIndices {
                        let localIdx = peak - offset
                        guard localIdx >= 0 && localIdx < plotArray.count else { continue }
                        let x = CGFloat(localIdx) * size.width / CGFloat(plotArray.count - 1)
                        let y = centerY - CGFloat(plotArray[localIdx]) * amplitudeScale
                        let yClamped = min(max(y, verticalMargin), size.height - verticalMargin)
                        let circle = Path(ellipseIn: CGRect(x: x-3, y: yClamped-3, width: 6, height: 6))
                        ctx.fill(circle, with: .color(.red))
                    }
                }
            }
        }
        .background(Color.black)
        .cornerRadius(8)
        // Force refresh at high rate to ensure smooth animation
        .onChange(of: data.count) { _ in
            // Trigger redraw when data changes
        }
        .onAppear {
            // Set up a timer for smoother updates
            Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                displayTime = Date() // This forces the view to refresh ~30 times per second
            }
        }
        // Use the display time to force refresh
        .id(displayTime)
    }
}
