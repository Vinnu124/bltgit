import Foundation

class GitClient: @unchecked Sendable {
    private let bridge: StreamBridge
    private let repo: RepoManager
    
    init(bridge: StreamBridge, repo: RepoManager) {
        self.bridge = bridge
        self.repo = repo
    }
    
    func pull() async throws {
        // Read refs
        var serverRefs: [String: String] = [:]
        while true {
            guard let line = try await PktLine.decodeFrom(stream: bridge) else { break } // flush
            let str = String(data: line, encoding: .utf8) ?? ""
            if let spaceIndex = str.firstIndex(of: " ") {
                 let hash = String(str[..<spaceIndex])
                 let nameWithCaps = String(str[str.index(after: spaceIndex)...])
                 let name = String(nameWithCaps.components(separatedBy: "\0")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                 if name != "capabilities^{}" {
                     serverRefs[name] = hash
                 }
            }
        }
        
        let localRefs = try repo.allRefs()
        var wants: [String] = []
        var haves: [String] = []
        
        for (name, hash) in serverRefs {
             if localRefs[name] != hash {
                 wants.append(hash)
             }
        }
        
        if wants.isEmpty {
             print("Already up to date.")
             try await bridge.write(data: PktLine.flush)
             return
        }
        
        haves = try repo.recentCommits()
        
        // Send wants
        var first = true
        for want in Set(wants) {
             let cap = first ? " multi_ack side-band-64k ofs-delta agent=bltgit/1.0" : ""
             try await bridge.write(data: PktLine.encode("want \(want)\(cap)\n"))
             first = false
        }
        try await bridge.write(data: PktLine.flush)
        
        // Send haves
        for have in haves {
             try await bridge.write(data: PktLine.encode("have \(have)\n"))
        }
        try await bridge.write(data: PktLine.encode("done\n"))
        
        // Read NAK (server's acknowledgement before sending pack)
        // The server sends a pkt-line "NAK\n" before starting chunked transfer.
        // We must consume it here to stay in sync with the protocol.
        _ = try await PktLine.decodeFrom(stream: bridge) // discard NAK

        // Read pack via chunked transfer
        let reporter = ProgressReporter(totalBytes: nil) // total unknown on client side
        let chunker = ChunkedTransfer(bridge: bridge)
        chunker.onProgress = { bytes in reporter.update(bytesDiff: bytes) }
        let packData = try await chunker.receive()
        reporter.finish()
        
        try repo.applyPack(data: packData)
        
        // Update all refs that differ from local
        for (name, hash) in serverRefs {
             if localRefs[name] != hash {
                 try repo.updateRef(name: name, hash: hash)
             }
        }
        
        // Point HEAD at the correct branch before checkout so working tree is populated.
        // In a fresh clone the default branch may not match what the server has.
        if let headBranch = serverRefs.keys.first(where: { $0.hasPrefix("refs/heads/") }) {
            try repo.setHead(to: headBranch)
        }
        
        // Checkout files into working directory
        try? repo.checkout()
        
        print("Pull complete.")
    }
    
    func push() async throws {
        // Read refs to see what server has
        var serverRefs: [String: String] = [:]
        while true {
            guard let line = try await PktLine.decodeFrom(stream: bridge) else { break } // flush
            let str = String(data: line, encoding: .utf8) ?? ""
            if let spaceIndex = str.firstIndex(of: " ") {
                 let hash = String(str[..<spaceIndex])
                 let nameWithCaps = String(str[str.index(after: spaceIndex)...])
                 let name = String(nameWithCaps.components(separatedBy: "\0")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                 if name != "capabilities^{}" {
                     serverRefs[name] = hash
                 }
            }
        }
        
        // Let's only handle pushing HEAD (the current checked out branch) for simplicity
        let localRefs = try repo.allRefs()
        guard let headHash = localRefs["HEAD"] else {
             print("Nothing to push (no HEAD).")
             return
        }
        
        let branchName = "refs/heads/main" // Defaulting to main, could look up actual HEAD symbol
        let serverHash = serverRefs[branchName] ?? "0000000000000000000000000000000000000000"
        
        if serverHash == headHash {
             print("Everything up to date.")
             try await bridge.write(data: PktLine.flush)
             return
        }
        
        // 1. Send want/update command
        let cap = " report-status side-band-64k agent=bltgit/1.0" 
        try await bridge.write(data: PktLine.encode("\(serverHash) \(headHash) \(branchName)\0\(cap)\n"))
        try await bridge.write(data: PktLine.flush)
        
        // 2. Generate packfile of what we have that server doesn't
        var haves: [String] = []
        if serverHash != "0000000000000000000000000000000000000000" {
            haves.append(serverHash)
        }
        
        let packData = try repo.generatePack(wants: [headHash], haves: haves)
        
        // 3. Send the packfile chunked
        let chunker = ChunkedTransfer(bridge: bridge)
        let reporter = ProgressReporter(totalBytes: packData.count)
        
        try await chunker.send(data: packData)
        reporter.finish()
        
        // 4. Read report status
        while true {
             guard let lineData = try await PktLine.decodeFrom(stream: bridge) else { break }
             let line = String(data: lineData, encoding: .utf8) ?? ""
             print("Server response: \(line.trimmingCharacters(in: .newlines))")
        }
        
        print("Push complete.")
    }
}
