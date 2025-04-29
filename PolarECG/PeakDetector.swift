//
//  PeakDetector.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import Foundation

struct PeakDetector {
    let samplingRate: Double
    let windowSize: Int
    let thresholdFactor: Double
    let adaptive: Bool

    init(samplingRate: Double = 130.0, windowSize: Int = 5, thresholdFactor: Double = 0.5, adaptive: Bool = false) {
        self.samplingRate = samplingRate
        self.windowSize = windowSize
        self.thresholdFactor = thresholdFactor
        self.adaptive = adaptive
    }

    func detectRRIntervals(from ecgData: [Double]) -> [Double] {
        let peakIndices = detectPeakIndices(from: ecgData)
        guard peakIndices.count > 1 else { return [] }
        var rr: [Double] = []
        for j in 1..<peakIndices.count {
            let dt = Double(peakIndices[j] - peakIndices[j-1]) / samplingRate
            rr.append(dt)
        }
        return rr
    }

    /// Robust R-peak detection using a simplified Pan-Tompkins approach with adaptive thresholding
    func detectPeakIndices(from ecgData: [Double]) -> [Int] {
        guard ecgData.count > Int(samplingRate) else { return [] }

        // 1. Bandpass filter (5-15 Hz, simple difference for demo)
        let hp = highPass(ecgData, window: Int(samplingRate * 0.2))
        let lp = lowPass(hp, window: Int(samplingRate * 0.08))

        // 2. Differentiate
        let diff = differentiate(lp)

        // 3. Square
        let squared = diff.map { $0 * $0 }

        // 4. Moving window integration
        let mwi = movingAverage(squared, windowSize: Int(samplingRate * 0.12))

        // 5. Adaptive threshold and peak search with refractory
        let minPeakDistance = Int(samplingRate * 0.3) // 300ms refractory

        var peaks: [Int] = []
        var i = 0
        while i < mwi.count {
            // --- Adaptive threshold: use local max in a 10s window, fallback to global max ---
            let localWin = adaptive ? Int(samplingRate * 10) : mwi.count
            let localStart = max(0, i - localWin/2)
            let localEnd = min(mwi.count - 1, i + localWin/2)
            let localMax = mwi[localStart...localEnd].max() ?? (mwi.max() ?? 0)
            let threshold = localMax * 0.3 // Lowered to 30% of local max for better detection during low amplitude

            if mwi[i] > threshold {
                let searchEnd = min(i + Int(samplingRate * 0.1), mwi.count - 1)
                let localMaxIdx = (i...searchEnd).max(by: { mwi[$0] < mwi[$1] }) ?? i

                // Correction: search for the true R-peak (maximum in original signal) near the detected QRS onset
                let searchRadius = Int(samplingRate * 0.08)
                let origStart = max(0, localMaxIdx - searchRadius)
                let origEnd = min(ecgData.count - 1, localMaxIdx + searchRadius)
                let origWindow = origStart...origEnd
                let rPeakIdx = origWindow.max(by: { ecgData[$0] < ecgData[$1] }) ?? localMaxIdx

                // Remove peaks that are too close and keep only the highest
                if let last = peaks.last, rPeakIdx - last < minPeakDistance {
                    if ecgData[rPeakIdx] > ecgData[last] {
                        peaks[peaks.count - 1] = rPeakIdx
                    }
                } else {
                    peaks.append(rPeakIdx)
                }
                i = localMaxIdx + minPeakDistance
            } else {
                i += 1
            }
        }
        return peaks
    }

    // High-pass filter (simple moving average subtraction)
    private func highPass(_ data: [Double], window: Int) -> [Double] {
        guard data.count > window else { return data }
        let ma = movingAverage(data, windowSize: window)
        return zip(data, ma).map { $0 - $1 }
    }

    // Low-pass filter (moving average)
    private func lowPass(_ data: [Double], window: Int) -> [Double] {
        movingAverage(data, windowSize: window)
    }

    // Differentiate signal
    private func differentiate(_ data: [Double]) -> [Double] {
        guard data.count > 1 else { return data }
        var diff: [Double] = [0]
        for i in 1..<data.count {
            diff.append(data[i] - data[i-1])
        }
        return diff
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
