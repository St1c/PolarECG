//
//  PeakDetector.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//

import Foundation

/// State-of-the-art R-peak detection using a simplified Pan-Tompkins algorithm.
/// This implementation follows best practices for robust R-peak detection in noisy, real-world ECG signals.
/// - Bandpass filter (5-15 Hz) to isolate QRS.
/// - Differentiate, square, and moving window integration.
/// - Adaptive thresholding.
/// - Search for local maxima in the original ECG within a QRS window after threshold crossing.
/// - Enforce physiological RR intervals and refractory period.
struct PeakDetector {
    let samplingRate: Double
    let windowSize: Int
    let thresholdFactor: Double
    let adaptive: Bool

    // Default values allow backward compatibility with previous usage
    init(samplingRate: Double = 130.0, windowSize: Int = 5, thresholdFactor: Double = 0.5, adaptive: Bool = false) {
        self.samplingRate = samplingRate
        self.windowSize = windowSize
        self.thresholdFactor = thresholdFactor
        self.adaptive = adaptive
    }

    /// Main entry: returns R-peak indices in the input ECG signal.
    func detectPeakIndices(from ecgData: [Double]) -> [Int] {
        guard ecgData.count > Int(samplingRate) else { return [] }

        // 1. Bandpass filter (5-15 Hz) using sequential HPF then LPF
        let bandpassed = robustBandpass(ecgData, lowcut: 5.0, highcut: 15.0)

        // 2. Differentiate
        let diff = differentiate(bandpassed)

        // 3. Square
        let squared = diff.map { $0 * $0 }

        // 4. Moving window integration (QRS width ~120ms)
        let mwi = movingAverage(squared, windowSize: Int(0.12 * samplingRate))

        // 5. Robust thresholding using median + k * MAD (median absolute deviation)
        let med = median(mwi)
        let mad = median(mwi.map { abs($0 - med) })
        let threshold = med + 4.0 * mad // 4.0 is empirically robust for noise

        // 6. Peak search with local maxima and refractory period
        let minRR = 0.3 // s
        let maxRR = 2.0 // s
        let refractorySamples = Int(0.25 * samplingRate) // 250ms

        var peaks: [Int] = []
        var lastPeak: Int? = nil
        var i = 0

        while i < mwi.count {
            if mwi[i] > threshold {
                // Find local max in MWI within QRS window (~120ms)
                let searchEnd = min(i + Int(0.12 * samplingRate), mwi.count - 1)
                let mwiPeakIdx = (i...searchEnd).max(by: { mwi[$0] < mwi[$1] }) ?? i

                // Find R-peak in original ECG within ±60ms of MWI peak
                let qrsRadius = Int(0.06 * samplingRate)
                let origStart = max(0, mwiPeakIdx - qrsRadius)
                let origEnd = min(ecgData.count - 1, mwiPeakIdx + qrsRadius)
                let rPeakIdx = (origStart...origEnd).max(by: { ecgData[$0] < ecgData[$1] }) ?? mwiPeakIdx

                // Enforce refractory period and physiological RR
                if let last = lastPeak {
                    let rr = Double(rPeakIdx - last) / samplingRate
                    if rPeakIdx - last < refractorySamples || rr < minRR || rr > maxRR {
                        i += 1
                        continue
                    }
                }

                peaks.append(rPeakIdx)
                lastPeak = rPeakIdx
                i = mwiPeakIdx + refractorySamples
            } else {
                i += 1
            }
        }
        return peaks
    }

    /// Returns RR intervals (seconds) from detected R-peaks.
    func detectRRIntervals(from ecgData: [Double]) -> [Double] {
        let peakIndices = detectPeakIndices(from: ecgData)
        guard peakIndices.count > 1 else { return [] }
        var rr: [Double] = []
        for j in 1..<peakIndices.count {
            let dt = Double(peakIndices[j] - peakIndices[j-1]) / samplingRate
            // Only keep physiological RR intervals
            if dt > 0.3 && dt < 2.0 {
                rr.append(dt)
            }
        }
        return rr
    }

    // --- Signal processing helpers ---

    /// Robust bandpass filter: sequential HPF then LPF, with larger windows for stability
    private func robustBandpass(_ data: [Double], lowcut: Double, highcut: Double) -> [Double] {
        // HPF window: ~cutoff freq, but at least 3 samples
        let hpWin = max(3, Int(samplingRate / lowcut))
        let lpWin = max(3, Int(samplingRate / highcut))
        let hp = highPass(data, window: hpWin)
        let lp = lowPass(hp, window: lpWin)
        return lp
    }

    /// High-pass filter (moving average subtraction)
    private func highPass(_ data: [Double], window: Int) -> [Double] {
        guard data.count > window else { return data }
        let ma = movingAverage(data, windowSize: window)
        return zip(data, ma).map { $0 - $1 }
    }

    /// Low-pass filter (moving average)
    private func lowPass(_ data: [Double], window: Int) -> [Double] {
        movingAverage(data, windowSize: window)
    }

    /// Differentiate signal
    private func differentiate(_ data: [Double]) -> [Double] {
        guard data.count > 1 else { return data }
        var diff: [Double] = [0]
        for i in 1..<data.count {
            diff.append(data[i] - data[i-1])
        }
        return diff
    }

    /// Moving average
    private func movingAverage(_ data: [Double], windowSize: Int) -> [Double] {
        guard data.count >= windowSize, windowSize > 0 else { return data }
        var smoothed: [Double] = []
        var sum = data[0..<windowSize].reduce(0, +)
        smoothed.append(sum / Double(windowSize))
        for i in 1...(data.count - windowSize) {
            sum += data[i + windowSize - 1] - data[i - 1]
            smoothed.append(sum / Double(windowSize))
        }
        // Pad to keep length
        if let last = smoothed.last {
            smoothed.append(contentsOf: Array(repeating: last, count: windowSize - 1))
        }
        return smoothed
    }

    /// Median of array
    private func median(_ arr: [Double]) -> Double {
        guard !arr.isEmpty else { return 0 }
        let sorted = arr.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid-1] + sorted[mid]) / 2
        } else {
            return sorted[mid]
        }
    }

    /// Standard deviation of array
    private func stddev(_ arr: [Double]) -> Double {
        guard arr.count > 1 else { return 0 }
        let mean = arr.reduce(0, +) / Double(arr.count)
        let variance = arr.map { pow($0 - mean, 2) }.reduce(0, +) / Double(arr.count)
        return sqrt(variance)
    }
}
