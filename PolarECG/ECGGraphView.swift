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
    
    // Remove the displayTime state and timer
    // Use State for animation frame to limit updates
    @State private var animationFrame = 0
    
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
                
                // Downsample data for rendering if it's too dense
                // This greatly improves performance when we have lots of data
                let maxPointsToDraw = 400 // Limit maximum points to draw
                let plotArray: [Double]
                let downsampleFactor = max(1, Int(plotData.count / maxPointsToDraw))
                if (downsampleFactor > 1) {
                    plotArray = stride(from: 0, to: plotData.count, by: downsampleFactor).map { plotData[Array<Any>.Index($0)] }
                } else {
                    plotArray = Array(plotData)
                }
                
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
                    guard plotArray.count > 1 else { return }
                    
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

                // Draw peaks as red circles - but only draw a reasonable number
                if let peakIndices = peakIndices {
                    let offset = data.count > windowCount ? data.count - windowCount : 0
                    let peakOffset = offset > stabilizationSamples ? offset : stabilizationSamples
                    
                    // Only draw peaks that fall within our plotted data
                    let filteredPeaks = peakIndices.filter { 
                        let localIdx = $0 - peakOffset
                        return localIdx >= 0 && localIdx < plotData.count
                    }
                    
                    // Limit the number of peaks we draw to avoid performance issues
                    let peaksToDraw = filteredPeaks.count > 50 ? 
                        filteredPeaks.suffix(50) : filteredPeaks
                        
                    for peak in peaksToDraw {
                        let localIdx = peak - peakOffset
                        guard localIdx >= 0 && localIdx < plotData.count else { continue }
                        
                        // Find appropriate index in our downsampled array
                        let displayIdx = Int(Double(localIdx) / Double(plotData.count) * Double(plotArray.count))
                        guard displayIdx >= 0 && displayIdx < plotArray.count else { continue }
                        
                        let x = CGFloat(displayIdx) * size.width / CGFloat(plotArray.count - 1)
                        let y = centerY - CGFloat(plotArray[displayIdx]) * amplitudeScale
                        let yClamped = min(max(y, verticalMargin), size.height - verticalMargin)
                        let circle = Path(ellipseIn: CGRect(x: x-3, y: yClamped-3, width: 6, height: 6))
                        ctx.fill(circle, with: .color(.green)) // Changed from .red to .green
                    }
                }
            }
        }
        .background(Color.black)
        .cornerRadius(8)
        // Only trigger redraws when data count changes significantly
        .onChange(of: data.count) { newCount in
            // Only update animation frame when we have meaningful data changes
            // (at least 10 new samples, or approximately 10/130 = 77ms of data)
            if newCount % 10 == 0 {
                animationFrame += 1
            }
        }
        // Use animationFrame for id - this limits view refreshes
        .id(animationFrame)
        // Use DisplayLink for more efficient animation if needed
        .onAppear {
            // Start a DisplayLink timer that's synchronized with screen refresh
            startDisplayLink()
        }
        .onDisappear {
            stopDisplayLink()
        }
    }
    
    // More efficient display refresh using CADisplayLink
    private func startDisplayLink() {
        // Create a timer that fires less frequently (e.g., 5 fps instead of 30)
        // This is just for smooth scrolling effect, not for every data update
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            // Update much less frequently - 5 fps is enough for smooth visual effect
            animationFrame += 1
        }
    }
    
    private func stopDisplayLink() {
        // Clean up any timers if needed
    }
}
