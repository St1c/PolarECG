import SwiftUI

struct VerticalSpeedGraphView: View {
    let verticalSpeedData: [(timestamp: Double, speed: Double)]

    var body: some View {
        GeometryReader { geo in
            let speeds = verticalSpeedData.map { $0.speed }
            let minSpeed = speeds.min() ?? -1
            let maxSpeed = speeds.max() ?? 1
            let range = maxSpeed - minSpeed == 0 ? 1 : maxSpeed - minSpeed
            let points = verticalSpeedData.suffix(geo.size.width > 0 ? Int(geo.size.width) : 100)
            Path { path in
                for (i, point) in points.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(points.count - 1)
                    let y = geo.size.height * CGFloat(1 - (point.speed - minSpeed) / range)
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.orange, lineWidth: 2)
        }
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            Text("Vertical Speed (z-axis, g/s)")
                .font(.caption2)
                .foregroundColor(.orange)
                .padding([.top, .leading], 6),
            alignment: .topLeading
        )
    }
}
