//
//  HRVCalculator.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import Foundation

/// Computes standard HRV metrics from RR intervals (in seconds)
struct HRVCalculator {
    static func computeRMSSD(from rrIntervals: [Double]) -> Double {
        guard rrIntervals.count > 1 else { return 0.0 }
        let diffs = zip(rrIntervals.dropFirst(), rrIntervals).map { $0 - $1 }
        let sq = diffs.map { $0 * $0 }
        let meanSq = sq.reduce(0, +) / Double(sq.count)
        // convert from seconds → ms
        return sqrt(meanSq) * 1000.0
    }

    static func computeSDNN(from rrIntervals: [Double]) -> Double {
        guard rrIntervals.count > 1 else { return 0.0 }
        let mean = rrIntervals.reduce(0, +) / Double(rrIntervals.count)
        let variance = rrIntervals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(rrIntervals.count)
        // convert from seconds → ms
        return sqrt(variance) * 1000.0
    }

    static func computeMeanHR(from rrIntervals: [Double]) -> Double {
        guard rrIntervals.count > 0 else { return 0.0 }
        let meanRR = rrIntervals.reduce(0, +) / Double(rrIntervals.count)
        return meanRR > 0 ? 60.0 / meanRR : 0.0
    }

    static func computeNN50(from rrIntervals: [Double]) -> Int {
        guard rrIntervals.count > 1 else { return 0 }
        let diffs = zip(rrIntervals.dropFirst(), rrIntervals).map { abs($0 - $1) }
        // NN50: number of pairs of successive RR intervals differing by more than 50 ms
        return diffs.filter { $0 > 0.05 }.count
    }

    static func computePNN50(from rrIntervals: [Double]) -> Double {
        guard rrIntervals.count > 1 else { return 0.0 }
        let nn50 = Double(computeNN50(from: rrIntervals))
        return (nn50 / Double(rrIntervals.count - 1)) * 100.0
    }
}
