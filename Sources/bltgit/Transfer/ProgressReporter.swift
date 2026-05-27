import Foundation

class ProgressReporter {
    private let totalBytes: Int?
    private var transferredBytes: Int = 0
    private let startTime: Date
    private var lastReportTime: Date
    
    init(totalBytes: Int? = nil) {
        self.totalBytes = totalBytes
        self.startTime = Date()
        self.lastReportTime = Date()
    }
    
    func update(bytesDiff: Int) {
        transferredBytes += bytesDiff
        let now = Date()
        
        // Report at most every 0.1 seconds to avoid terminal flicker
        if now.timeIntervalSince(lastReportTime) > 0.1 || transferredBytes == totalBytes {
            lastReportTime = now
            report()
        }
    }
    
    private func report() {
        let elapsed = Date().timeIntervalSince(startTime)
        let speed = elapsed > 0 ? (Double(transferredBytes) / 1024.0) / elapsed : 0.0
        
        let output: String
        if let total = totalBytes {
            let percentage = (Double(transferredBytes) / Double(total)) * 100.0
            output = String(format: "\rTransferring... %.1f%% (%d/%d bytes) at %.1f KB/s ", percentage, transferredBytes, total, speed)
        } else {
            output = String(format: "\rTransferring... %d bytes at %.1f KB/s ", transferredBytes, speed)
        }
        
        FileHandle.standardError.write(output.data(using: .utf8)!)
    }
    
    func finish() {
        report()
        FileHandle.standardError.write("\n".data(using: .utf8)!)
    }
}
