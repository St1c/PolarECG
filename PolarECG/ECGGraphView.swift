//
//  ECGGraphView.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import SwiftUI

struct ECGGraphView: View {
    let data: [Double]

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard data.count > 1 else { return }
                let path = Path { p in
                    let step = size.width / CGFloat(data.count - 1)
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    for (i, v) in data.enumerated() {
                        let x = CGFloat(i) * step
                        // scale & invert for display; tune multiplier as needed
                        let y = size.height / 2 - CGFloat(v * 100)
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                ctx.stroke(path, with: .color(.green), lineWidth: 1.5)
            }
        }
        .background(Color.black)
        .cornerRadius(8)
    }
}
