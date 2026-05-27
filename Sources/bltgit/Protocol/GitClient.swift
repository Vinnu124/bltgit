import Foundation

class GitClient {
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
        
        // Read pack
        let chunker = ChunkedTransfer(bridge: bridge)
        let packData = try await chunker.receive()
        
        try repo.applyPack(data: packData)
        
        for (name, hash) in serverRefs {
             if localRefs[name] != hash {
                 try repo.updateRef(name: name, hash: hash)
             }
        }
        print("Pull complete.")
    }
}
