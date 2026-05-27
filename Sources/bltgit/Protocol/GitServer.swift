import Foundation

class GitServer {
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
        
        // Read client wants
        var wants: [String] = []
        var haves: [String] = []
        
        while true {
            guard let lineData = try await PktLine.decodeFrom(stream: bridge) else { break }
            let line = String(data: lineData, encoding: .utf8) ?? ""
            if line.hasPrefix("want ") {
                 let parts = line.components(separatedBy: .whitespaces)
                 if parts.count >= 2 {
                     wants.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                 }
            } else if line.hasPrefix("have ") {
                 let parts = line.components(separatedBy: .whitespaces)
                 if parts.count >= 2 {
                     haves.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                 }
            } else if line.hasPrefix("done") {
                 break
            }
        }
        
        if wants.isEmpty {
             print("Client needs nothing.")
             return
        }
        
        // Generate pack
        let packData = try repo.generatePack(wants: wants, haves: haves)
        
        // Send sideband pack
        // We will just send it as one block for now in sideband 1 (data), chunked by ChunkedTransfer
        try await bridge.write(data: PktLine.encode("NAK\n"))
        
        let reporter = ProgressReporter(totalBytes: packData.count)
        
        let chunker = ChunkedTransfer(bridge: bridge)
        try await chunker.send(data: packData)
        
        reporter.finish()
        print("Server pull complete")
    }
}
