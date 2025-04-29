//
//  PeakDetector.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import Foundation

struct PeakDetector {
    let samplingRate = 130.0
    let windowSize = 5 // moving average window
    let thresholdFactor = 0.5 // threshold is dynamic: 50% of signal mean

    func detectRRIntervals(from ecgData: [Double]) -> [Double] {
        guard ecgData.count >= 3 else { return [] }
        let smoothed = movingAverage(ecgData, windowSize: windowSize)
        let dynamicThreshold = smoothed.map { $0 }.reduce(0, +) / Double(smoothed.count) * thresholdFactor

        var peakIndices: [Int] = []
        for i in 1..<(smoothed.count-1) {
            let v = smoothed[i]
            if v > dynamicThreshold && v > smoothed[i-1] && v > smoothed[i+1] {
                peakIndices.append(i)
            }
        }

        guard peakIndices.count > 1 else {
            return []
        }

        var rr: [Double] = []
        for j in 1..<peakIndices.count {
            let dt = Double(peakIndices[j] - peakIndices[j-1]) / samplingRate
            rr.append(dt)
        }
        return rr
    }

    private func movingAverage(_ data: [Double], windowSize: Int) -> [Double] {
        guard data.count >= windowSize, windowSize > 0 else { return data }
        var smoothed: [Double] = []
        for i in 0..<(data.count - windowSize + 1) {
            let window = data[i..<(i + windowSize)]
            let average = window.reduce(0, +) / Double(windowSize)
            smoothed.append(average)
        }
        if let last = smoothed.last {
            smoothed.append(contentsOf: Array(repeating: last, count: windowSize - 1))
        }
        return smoothed
    }
}
