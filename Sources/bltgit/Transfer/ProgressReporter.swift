import Foundation

/// Displays a live spinner + progress bar in the terminal using ANSI escape codes.
class ProgressReporter {
    private let totalBytes: Int?
    private var transferredBytes: Int = 0
    private let startTime: Date
    private var lastReportTime: Date
    private var spinnerIndex: Int = 0

    // Braille-dot spinner frames — gives a smooth "loading" feel
    private let spinnerFrames = ["⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"]

    init(totalBytes: Int? = nil) {
        self.totalBytes = totalBytes
        self.startTime = Date()
        self.lastReportTime = Date.distantPast // force first print immediately
        // Hide cursor for cleaner animation
        print("\u{1B}[?25l", terminator: "")
        fflush(stdout)
    }

    func update(bytesDiff: Int) {
        transferredBytes += bytesDiff
        spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
        let now = Date()
        // Throttle to ~15 fps to avoid flooding the terminal
        if now.timeIntervalSince(lastReportTime) >= 0.067 || transferredBytes == totalBytes {
            lastReportTime = now
            render()
        }
    }

    private func render() {
        let elapsed = Date().timeIntervalSince(startTime)
        let kbps = elapsed > 0 ? (Double(transferredBytes) / 1024.0) / elapsed : 0.0
        let spinner = spinnerFrames[spinnerIndex]

        let line: String
        if let total = totalBytes, total > 0 {
            let pct = min(100.0, (Double(transferredBytes) / Double(total)) * 100.0)
            let filled = Int(pct / 5)   // 20-char wide bar
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
            line = String(format: "\r\u{1B}[K %@ [%@] %5.1f%%  %d/%d bytes  %.1f KB/s ",
                          spinner, bar, pct, transferredBytes, total, kbps)
        } else {
            line = String(format: "\r\u{1B}[K %@ Transferring...  %d bytes  %.1f KB/s ",
                          spinner, transferredBytes, kbps)
        }

        // Write directly to stdout so it lands on the same fd as print()
        print(line, terminator: "")
        fflush(stdout)
    }

    func finish() {
        // Force final render with 100% if total known
        if let total = totalBytes {
            transferredBytes = total
        }
        render()

        let elapsed = Date().timeIntervalSince(startTime)
        let kbps = elapsed > 0 ? (Double(transferredBytes) / 1024.0) / elapsed : 0.0
        print(String(format: "\n\u{1B}[?25h✓ Transfer complete — %d bytes in %.2fs (%.1f KB/s)",
                     transferredBytes, elapsed, kbps))
        fflush(stdout)
    }
}
