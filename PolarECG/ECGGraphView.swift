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
    
    // Ignore first few seconds for stabilization
    private let stabilizationPeriod: Double = 3.0

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                // Only plot the last 2s window, after stabilization
                let windowSeconds: Double = 2.0
                let windowCount = Int(samplingRate * windowSeconds)
                let stabilizationSamples = Int(samplingRate * stabilizationPeriod)
                let plotDataRaw = data.suffix(windowCount + stabilizationSamples)
                let plotData = plotDataRaw.count > stabilizationSamples
                    ? plotDataRaw.dropFirst(stabilizationSamples)
                    : []
                guard plotData.count > 1 else { return }
                let plotArray = Array(plotData)
                let amplitudeScale: CGFloat = 60 // larger = smaller amplitude
                let verticalMargin: CGFloat = size.height * 0.15
                let centerY = size.height / 2

                // --- ECG-style grid (25 mm/s paper) ---
                // 1 mm = 40 ms at 25 mm/s
                let mmPerSecond: CGFloat = 25.0
                let totalMm = mmPerSecond * CGFloat(windowSeconds)
                let mmWidth = size.width / totalMm

                // Draw vertical grid lines: all same color as x-axis, thin and thick lines
                let numVerticalLines = Int(totalMm)
                let gridLineColor = Color.gray.opacity(0.5)
                for i in 0...numVerticalLines {
                    let x = CGFloat(i) * mmWidth
                    let isLargeBox = (i % 5 == 0)
                    let lineWidth: CGFloat = isLargeBox ? 1.0 : 0.5
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(gridLineColor), lineWidth: lineWidth)
                }

                // Draw horizontal grid lines (keep as before: 10 per plot)
                for i in 0...10 {
                    let y = CGFloat(i) * size.height / 10
                    let lineWidth: CGFloat = (i % 5 == 0) ? 1.0 : 0.5
                    let color = (i % 5 == 0)
                        ? Color.red.opacity(0.25)
                        : Color.red.opacity(0.10)
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
                }

                // --- Baseline at y=0 ---
                let baselineY = centerY
                var baselinePath = Path()
                baselinePath.move(to: CGPoint(x: 0, y: baselineY))
                baselinePath.addLine(to: CGPoint(x: size.width, y: baselineY))
                ctx.stroke(baselinePath, with: .color(.gray.opacity(0.5)), lineWidth: 1)

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
                ctx.stroke(path, with: .color(.red), lineWidth: 1.5) // Changed from .green to .red

                // Draw peaks as red circles
                if let peakIndices = peakIndices {
                    let offset = data.count > windowCount ? data.count - windowCount : 0
                    let peakOffset = offset > stabilizationSamples ? offset : stabilizationSamples
                    for peak in peakIndices {
                        let localIdx = peak - peakOffset
                        guard localIdx >= 0 && localIdx < plotArray.count else { continue }
                        let x = CGFloat(localIdx) * size.width / CGFloat(plotArray.count - 1)
                        let y = centerY - CGFloat(plotArray[localIdx]) * amplitudeScale
                        let yClamped = min(max(y, verticalMargin), size.height - verticalMargin)
                        let circle = Path(ellipseIn: CGRect(x: x-3, y: yClamped-3, width: 6, height: 6))
                        ctx.fill(circle, with: .color(.green)) // Changed from .red to .green
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
