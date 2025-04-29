import Foundation

struct RobustHRVResult {
    let rmssd: Double
    let sdnn: Double
    let meanHR: Double
    let nn50: Int
    let pnn50: Double
    let rrCount: Int
}
