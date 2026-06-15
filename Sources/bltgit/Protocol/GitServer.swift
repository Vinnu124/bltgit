import Foundation

class GitServer: @unchecked Sendable {
    private let bridge: StreamBridge
    private let repo: RepoManager
    
    init(bridge: StreamBridge, repo: RepoManager) {
        self.bridge = bridge
        self.repo = repo
    }
    
    func pull() async throws {
        // Send all refs
        let refs = try repo.allRefs()
        var first = true
        for (name, hash) in refs {
            let cap = first ? "\0multi_ack side-band-64k ofs-delta agent=bltgit/1.0" : ""
            try await bridge.write(data: PktLine.encode("\(hash) \(name)\(cap)\n"))
            first = false
        }
        if first {
             // No refs, send capabilities anyway
             try await bridge.write(data: PktLine.encode("0000000000000000000000000000000000000000 capabilities^{}\0multi_ack side-band-64k ofs-delta agent=bltgit/1.0\n"))
        }
        try await bridge.write(data: PktLine.flush)
        
        // Read client wants, push commands, or a bltgit-log request until flush
        var wants: [String] = []
        var haves: [String] = []
        var pushCommands: [(String, String, String)] = []
        var isPush = false
        var isLog = false

        // Phase 1: read commands until flush
        while true {
            guard let lineData = try await PktLine.decodeFrom(stream: bridge) else { break } // flush ends phase 1
            let line = String(data: lineData, encoding: .utf8) ?? ""
            if line.hasPrefix("want ") {
                let parts = line.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    wants.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines) == "bltgit-log" {
                isLog = true
            } else if line.count >= 82 && line.contains("refs/") {
                // Push command: old_hash new_hash refname
                isPush = true
                let parts = line.components(separatedBy: " ")
                if parts.count >= 3 {
                    pushCommands.append((parts[0], parts[1], parts[2].components(separatedBy: "\0")[0].trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        
        // Phase 2: read haves and "done" (only for pull; log and push skip this).
        // IMPORTANT: these bytes MUST be consumed before we start chunked transfer,
        // otherwise they corrupt the ACK reads.
        if !isPush && !isLog {
            while true {
                guard let lineData = try await PktLine.decodeFrom(stream: bridge) else { break }
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if line.hasPrefix("have ") {
                    let parts = line.components(separatedBy: .whitespaces)
                    if parts.count >= 2 {
                        haves.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } else if line.hasPrefix("done") {
                    break
                }
            }
        }

        // Handle log request: run git log and stream lines back as pkt-lines.
        if isLog {
            let logLines = (try? repo.gitLog()) ?? []
            if logLines.isEmpty {
                try await bridge.write(data: PktLine.encode("(no commits yet)\n"))
            } else {
                for line in logLines {
                    try await bridge.write(data: PktLine.encode(line + "\n"))
                }
            }
            try await bridge.write(data: PktLine.flush)
            return
        }
        
        if isPush {
            // Handle incoming push — receive the pack with a live progress bar.
            print("Receiving push pack...")
            let pushChunker = ChunkedTransfer(bridge: bridge)
            let pushReporter = ProgressReporter()
            pushChunker.onProgress = { bytes in pushReporter.update(bytesDiff: bytes) }
            let packData = try await pushChunker.receive()
            pushReporter.finish()

            do {
                if packData.count > 0 {
                    try repo.applyPack(data: packData)
                }

                for cmd in pushCommands {
                    try repo.updateRef(name: cmd.2, hash: cmd.1)
                }

                // Send success report
                try await bridge.write(data: PktLine.encode("unpack ok\n"))
                for cmd in pushCommands {
                    try await bridge.write(data: PktLine.encode("ok \(cmd.2)\n"))
                }
                try await bridge.write(data: PktLine.flush)
                print("Server push complete.")
            } catch {
                try await bridge.write(data: PktLine.encode("unpack \(error.localizedDescription)\n"))
                try await bridge.write(data: PktLine.flush)
                print("Server push failed: \(error)")
            }
            return
        }
        
        if wants.isEmpty {
             print("Client needs nothing.")
             return
        }
        
        // Generate pack and send with a live progress bar.
        let packData = try repo.generatePack(wants: wants, haves: haves)
        print("Sending pack (\(packData.count) bytes)...")

        try await bridge.write(data: PktLine.encode("NAK\n"))

        let chunker = ChunkedTransfer(bridge: bridge)
        let reporter = ProgressReporter(totalBytes: packData.count)
        chunker.onProgress = { bytes in reporter.update(bytesDiff: bytes) }
        try await chunker.send(data: packData)
        reporter.finish()
        print("Server pull complete")
    }
}
