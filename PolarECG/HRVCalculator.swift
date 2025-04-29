//
//  HRVCalculator.swift
//  PolarECG
//
//  Created by Bruno Gardlo on 29/04/2025.
//


import Foundation

/// Computes standard HRV metric RMSSD (in milliseconds)
struct HRVCalculator {
    static func computeRMSSD(from rrIntervals: [Double]) -> Double {
        guard rrIntervals.count > 1 else { return 0.0 }
        let diffs = zip(rrIntervals.dropFirst(), rrIntervals).map { $0 - $1 }
        let sq = diffs.map { $0 * $0 }
        let meanSq = sq.reduce(0, +) / Double(sq.count)
        // convert from seconds → ms
        return sqrt(meanSq) * 1000.0
    }
}
