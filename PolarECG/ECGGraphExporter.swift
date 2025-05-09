import UIKit

struct ECGGraphExporter {
    // Updated to access archived session data if available
    static func exportECGGraph(
        data: [Double],
        samplingRate: Double,
        peakIndices: [Int]?,
        archivedSessionData: [String: Any]? = nil
    ) -> URL? {
        // Parameters
        let secondsToExport: Double = 60.0
        let mmPerSecond: CGFloat = 25.0
        let mmPerRow: CGFloat = mmPerSecond * 10 // 10s per row
        let rows: Int = 6
        let secondsPerRow: Double = 10.0
        let mmHeightPerRow: CGFloat = 40 // 40mm per row (arbitrary, looks good)
        let pixelsPerMm: CGFloat = 8 // 8 px per mm (high-res)
        let width = mmPerRow * pixelsPerMm
        let height = mmHeightPerRow * CGFloat(rows) * pixelsPerMm

        // Prepare data - use archived data if available
        let ecgArray: [Double]
        let totalSamples = Int(samplingRate * secondsToExport)
        
        if let archived = archivedSessionData, let archivedECG = archived["ecg"] as? [Double] {
            ecgArray = Array(archivedECG.suffix(totalSamples))
        } else {
            let ecg = data.suffix(totalSamples)
            ecgArray = Array(ecg)
        }
        
        guard ecgArray.count > 1 else { return nil }
        let amplitudeScale: CGFloat = mmHeightPerRow * 1.8 // Further increased amplitude (was 1.0)

        // --- ECG annotation parameters ---
        let font = UIFont.systemFont(ofSize: 22, weight: .bold)
        let smallFont = UIFont.systemFont(ofSize: 16, weight: .regular)
        let textColor = UIColor.black

        // --- HRV/HR summary ---
        // Use provided archived data first, then fall back to file
        var robustSummary: [String: Any]? = nil
        
        if let archived = archivedSessionData, let summary = archived["robustHRVSummary"] as? [String: Any] {
            robustSummary = summary
        } else if let url = latestRobustHRVSummaryURL(),
                  let robustData = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: robustData) as? [String: Any] {
            robustSummary = obj
        }

        // Fallback: try to get current HR and HRV from UserDefaults (set by app)
        let currentHR = UserDefaults.standard.double(forKey: "currentHR")
        let currentHRV = UserDefaults.standard.double(forKey: "currentHRV")

        // Create image context
        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), false, 2.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        // Draw background
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Draw mm paper grid
        for row in 0..<rows {
            let yOffset = CGFloat(row) * mmHeightPerRow * pixelsPerMm
            // Vertical grid (1mm and 5mm)
            for i in 0...Int(mmPerRow) {
                let x = CGFloat(i) * pixelsPerMm
                let lineWidth: CGFloat = (i % 5 == 0) ? 1.0 : 0.5
                ctx.setStrokeColor(UIColor.red.withAlphaComponent(i % 5 == 0 ? 0.25 : 0.10).cgColor)
                ctx.setLineWidth(lineWidth)
                ctx.move(to: CGPoint(x: x, y: yOffset))
                ctx.addLine(to: CGPoint(x: x, y: yOffset + mmHeightPerRow * pixelsPerMm))
                ctx.strokePath()
            }
            // Horizontal grid (1mm and 5mm)
            for i in 0...Int(mmHeightPerRow) {
                let y = yOffset + CGFloat(i) * pixelsPerMm
                let lineWidth: CGFloat = (i % 5 == 0) ? 1.0 : 0.5
                ctx.setStrokeColor(UIColor.red.withAlphaComponent(i % 5 == 0 ? 0.25 : 0.10).cgColor)
                ctx.setLineWidth(lineWidth)
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: width, y: y))
                ctx.strokePath()
            }
        }

        // Draw ECG trace row by row
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(2.0)
        for row in 0..<rows {
            let rowStart = Int(Double(row) * secondsPerRow * samplingRate)
            let rowEnd = min(ecgArray.count, Int(Double(row+1) * secondsPerRow * samplingRate))
            guard rowEnd > rowStart else { continue }
            let rowData = ecgArray[rowStart..<rowEnd]
            let yOffset = CGFloat(row) * mmHeightPerRow * pixelsPerMm
            let centerY = yOffset + mmHeightPerRow * pixelsPerMm / 2
            let points = rowData.enumerated().map { (i, v) -> CGPoint in
                let x = CGFloat(i) * (mmPerRow * pixelsPerMm) / CGFloat(rowData.count - 1)
                let y = centerY - CGFloat(v) * amplitudeScale
                return CGPoint(x: x, y: y)
            }
            ctx.beginPath()
            ctx.move(to: points.first!)
            for pt in points.dropFirst() {
                ctx.addLine(to: pt)
            }
            ctx.strokePath()
        }

        // --- Draw axis and calibration descriptions ---
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left

        // X axis: 25 mm/s, Y axis: 10 mm/mV (standard), 1 mV = 10 mm
        let xLabel = "25 mm/s"
        let yLabel = "10 mm/mV"
        let calLabel = "1 mV = 10 mm"
        let durationLabel = "Duration: \(Int(secondsToExport)) s"
        let samplingLabel = "Sampling: \(Int(samplingRate)) Hz"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: smallFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]

        // Draw labels at the top left
        let margin: CGFloat = 18
        let yStart: CGFloat = margin

        // --- Draw white window for text ---
        let textWindowWidth: CGFloat = 340
        let textWindowHeight: CGFloat = 220
        let textWindowRect = CGRect(x: margin - 8, y: yStart - 8, width: textWindowWidth, height: textWindowHeight)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.92).cgColor)
        ctx.fill(textWindowRect)

        (xLabel as NSString).draw(at: CGPoint(x: margin, y: yStart), withAttributes: attributes)
        (yLabel as NSString).draw(at: CGPoint(x: margin, y: yStart + 32), withAttributes: attributes)
        (calLabel as NSString).draw(at: CGPoint(x: margin, y: yStart + 64), withAttributes: attributes)
        (durationLabel as NSString).draw(at: CGPoint(x: margin, y: yStart + 96), withAttributes: smallAttributes)
        (samplingLabel as NSString).draw(at: CGPoint(x: margin, y: yStart + 120), withAttributes: smallAttributes)

        // --- Draw robust HRV summary or fallback HR/HRV ---
        let summaryY = yStart + 160
        if let robust = robustSummary {
            // Try both top-level and nested "robustHRVSummary" key
            let summary: [String: Any]
            if let nested = robust["robustHRVSummary"] as? [String: Any] {
                summary = nested
            } else {
                summary = robust
            }
            let rmssd = summary["rmssd"] as? Double ?? 0
            let sdnn = summary["sdnn"] as? Double ?? 0
            let meanHR = summary["meanHR"] as? Double ?? 0
            let nn50 = summary["nn50"] as? Int ?? 0
            let pnn50 = summary["pnn50"] as? Double ?? 0
            let beats = summary["beats"] as? Int ?? 0
            let robustText =
                "Robust HRV (5 min):\n" +
                "RMSSD: \(String(format: "%.1f", rmssd)) ms\n" +
                "SDNN: \(String(format: "%.1f", sdnn)) ms\n" +
                "Mean HR: \(String(format: "%.1f", meanHR)) BPM\n" +
                "NN50: \(nn50)\n" +
                "pNN50: \(String(format: "%.1f", pnn50)) %\n" +
                "Beats: \(beats)"
            (robustText as NSString).draw(at: CGPoint(x: margin, y: summaryY), withAttributes: smallAttributes)
        } else {
            let fallbackText =
                "HR: \(currentHR > 0 ? String(format: "%.0f", currentHR) : "-") BPM\n" +
                "HRV (RMSSD): \(currentHRV > 0 ? String(format: "%.1f", currentHRV) : "-") ms"
            (fallbackText as NSString).draw(at: CGPoint(x: margin, y: summaryY), withAttributes: smallAttributes)
        }

        // Draw a calibration pulse (1 mV = 10 mm) at the bottom left
        let calPulseX: CGFloat = margin
        let calPulseY: CGFloat = height - margin - 2 * pixelsPerMm
        let calPulseWidth: CGFloat = 10 * pixelsPerMm // 10 mm
        let calPulseHeight: CGFloat = 10 * pixelsPerMm // 10 mm = 1 mV
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(3.0)
        ctx.move(to: CGPoint(x: calPulseX, y: calPulseY))
        ctx.addLine(to: CGPoint(x: calPulseX, y: calPulseY - calPulseHeight))
        ctx.addLine(to: CGPoint(x: calPulseX + calPulseWidth, y: calPulseY - calPulseHeight))
        ctx.addLine(to: CGPoint(x: calPulseX + calPulseWidth, y: calPulseY))
        ctx.strokePath()

        // Get image and save as JPG
        guard let image = UIGraphicsGetImageFromCurrentImageContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()
        guard let jpgData = image.jpegData(compressionQuality: 0.95) else { return nil }

        // Save to Documents
        let filename = "ecg_graph_\(Int(Date().timeIntervalSince1970)).jpg"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try jpgData.write(to: url)
        } catch {
            print("Failed to save ECG graph image:", error)
            return nil
        }

        // After creating and saving the image, clean up old graph files
        cleanupOldGraphFiles()
        
        return url
    }

    // Helper to get robust HRV summary file URL (if your app saves it somewhere)
    private static func getRobustSummaryURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("robust_hrv_summary.json")
    }

    // Helper to get the latest robust HRV summary file in Documents directory
    private static func latestRobustHRVSummaryURL() -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Look for files named "ecg_export_*.json" and pick the latest one
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        let jsons = files.filter { $0.lastPathComponent.hasPrefix("ecg_export_") && $0.pathExtension == "json" }
        let sorted = jsons.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return d1 > d2
        }
        return sorted.first
    }

    // Clean up old graph files
    private static func cleanupOldGraphFiles() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default
        
        do {
            let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.creationDateKey], options: [])
            let graphFiles = files.filter { $0.lastPathComponent.hasPrefix("ecg_graph_") }
            
            // Keep only 10 most recent graph files
            if graphFiles.count > 10 {
                let sortedFiles = graphFiles.sorted { (file1, file2) -> Bool in
                    let date1 = try? file1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                    let date2 = try? file2.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                    return date1! > date2!
                }
                
                for file in sortedFiles.suffix(from: 10) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            print("Error cleaning up graph files: \(error)")
        }
    }
}
