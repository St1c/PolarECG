import SwiftUI

struct VerticalSpeedGraphView: View {
    let verticalSpeedData: [(timestamp: Double, speed: Double)]
    let zData: [(timestamp: Double, z: Double)]
    let peaks: [(timestamp: Double, value: Double)]
    let jumpEvents: [(takeoffIdx: Int, landingIdx: Int, heightCm: Double)]
    let jumpHeights: [Double]

    var body: some View {
        GeometryReader { geo in
            // Filter data to show only last 15s for jump detection mode
            let isJumpMode = !jumpEvents.isEmpty
            
            // When in jump mode, limit to last 15s of data (50Hz * 15s = 750 samples)
            let windowLength = isJumpMode ? 750 : 3000
            let points = Array(zData.suffix(windowLength))
            
            // 1. simplify z-values range
            let zVals = points.map { $0.z }
            
            // Draw a reference coordinate frame
            let baselineY = geo.size.height / 2
            
            // Draw horizontal zero line
            Path { path in
                path.move(to: CGPoint(x: 0, y: baselineY))
                path.addLine(to: CGPoint(x: geo.size.width, y: baselineY))
            }
            .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            
            // Draw z-acceleration curve with a clearer line
            Path { path in
                guard points.count > 1 else { return }
                
                let stepX = geo.size.width / CGFloat(points.count > 1 ? points.count - 1 : 1)
                let offset = baselineY
                let scale = geo.size.height / 4  // Scale to fill half the height
                
                for i in 0..<points.count {
                    let x = CGFloat(i) * stepX
                    // Invert so positive is up, and scale
                    let y = offset - CGFloat(points[i].z) * scale
                    
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.cyan, lineWidth: 1.5)

            // Draw peak markers that correctly map to the points
            ForEach(peaks.indices, id: \.self) { idx in
                let peak = peaks[idx]
                
                // Find matching point in our data array using the timestamp
                if let pointIdx = points.firstIndex(where: { 
                    abs($0.timestamp - peak.timestamp) < 10  // Allow small timestamp difference
                }) {
                    let x = geo.size.width * CGFloat(pointIdx) / CGFloat(max(points.count - 1, 1))
                    
                    // Use same calculation as the signal curve
                    let offset = baselineY
                    let scale = geo.size.height / 4
                    let y = offset - CGFloat(peak.value) * scale
                    
                    // Make peak marker larger and more visible
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Circle()
                            .stroke(Color.white, lineWidth: 1)
                            .frame(width: 12, height: 12)
                    }
                    .position(x: x, y: y)
                    
                    // Show peak value with better visibility
                    Text(String(format: "%.2f", peak.value))
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(3)
                        .position(x: x, y: y - 15)
                }
            }

            // Draw jump events - FIXED to avoid index out of range
            ForEach(jumpEvents.indices, id: \.self) { idx in
                let event = jumpEvents[idx]
                
                // FIXED: Don't use original indices directly - use relative positions instead
                // The jump events may have indices from the original full dataset,
                // but we're showing only a window of that data
                
                // Calculate relative positions (0.0-1.0) in the graph
                let relTakeoff = min(1.0, max(0.0, Double(event.takeoffIdx) / Double(max(1, windowLength))))
                let relLanding = min(1.0, max(0.0, Double(event.landingIdx) / Double(max(1, windowLength))))
                
                // Convert to x positions in our display
                let xTake = CGFloat(relTakeoff) * geo.size.width
                let xLand = CGFloat(relLanding) * geo.size.width
                
                // Calculate y positions safely
                let takeoffIdx = Int(relTakeoff * Double(points.count - 1))
                let landingIdx = Int(relLanding * Double(points.count - 1))
                
                // Safety check indices to avoid out of range errors
                let takeValue = takeoffIdx >= 0 && takeoffIdx < points.count ? points[takeoffIdx].z : 0
                let landValue = landingIdx >= 0 && landingIdx < points.count ? points[landingIdx].z : 0
                
                let yTake = baselineY - CGFloat(takeValue) * (geo.size.height / 4)
                let yLand = baselineY - CGFloat(landValue) * (geo.size.height / 4)
                
                // Draw flight path curve
                Path { path in
                    path.move(to: CGPoint(x: xTake, y: yTake))
                    
                    // Parabolic flight path
                    let cp1x = xTake + (xLand - xTake) * 0.25
                    let cp1y = min(yTake, yLand) - 40
                    let cp2x = xTake + (xLand - xTake) * 0.75
                    let cp2y = min(yTake, yLand) - 40
                    
                    path.addCurve(
                        to: CGPoint(x: xLand, y: yLand),
                        control1: CGPoint(x: cp1x, y: cp1y),
                        control2: CGPoint(x: cp2x, y: cp2y)
                    )
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
                
                // Takeoff marker
                ZStack {
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 12, height: 12)
                    Text("T")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black)
                }
                .position(x: xTake, y: yTake)
                
                // Landing marker
                ZStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                    Text("L")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.black)
                }
                .position(x: xLand, y: yLand)
                
                // Jump height label with better visibility
                Text("Jump: \(String(format: "%.1f", event.heightCm)) cm")
                    .font(.caption)
                    .padding(4)
                    .background(Color.yellow.opacity(0.7))
                    .foregroundColor(.black)
                    .cornerRadius(4)
                    .position(x: (xTake + xLand) / 2, y: min(yTake, yLand) - 25)
            }
        }
        .background(Color.black.opacity(0.3))
        .cornerRadius(8)
        .overlay(
            VStack(alignment: .leading) {
                // Adjust title based on mode
                let title = !jumpEvents.isEmpty ? 
                    "Jump Detection (last 15s)" : 
                    "Z-Acceleration"
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.orange)
                
                if !jumpEvents.isEmpty {
                    Text("\(jumpEvents.count) jumps detected")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
            .padding([.top, .leading], 6),
            alignment: .topLeading
        )
    }
}
