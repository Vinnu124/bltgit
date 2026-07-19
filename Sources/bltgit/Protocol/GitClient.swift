import Foundation

class GitClient: @unchecked Sendable {
    private let bridge: StreamBridge
    private let repo: RepoManager

    init(bridge: StreamBridge, repo: RepoManager) {
        self.bridge = bridge
        self.repo = repo
    }

    // MARK: - Public commands

    /// Download new commits and merge them into the local working tree.
    func pull() async throws {
        guard let (serverRefs, packData) = try await negotiateAndReceivePack() else {
            print("Already up to date.")
            return
        }

        try repo.applyPack(data: packData)

        let localRefs = try repo.allRefs()
        for (name, hash) in serverRefs where localRefs[name] != hash {
            try repo.updateRef(name: name, hash: hash)
        }

        // Point HEAD at the correct branch before checkout so the working tree is populated.
        if let headBranch = serverRefs.keys.first(where: { $0.hasPrefix("refs/heads/") }) {
            try repo.setHead(to: headBranch)
        }

        try? repo.checkout()
        print("Pull complete.")
    }

    /// Download new commits into refs/remotes/bltgit/<branch> without touching the working tree.
    /// Mirrors what `git fetch` does: you can inspect and merge at your own pace.
    func fetch() async throws {
        guard let (serverRefs, packData) = try await negotiateAndReceivePack() else {
            print("Already up to date.")
            return
        }

        try repo.applyPack(data: packData)

        // Write fetched commits under refs/remotes/bltgit/ so local branches are untouched.
        var updatedRefs: [String] = []
        for (name, hash) in serverRefs where name.hasPrefix("refs/heads/") {
            let branch = String(name.dropFirst("refs/heads/".count))
            let remoteRef = "refs/remotes/bltgit/\(branch)"
            try repo.updateRef(name: remoteRef, hash: hash)
            updatedRefs.append(remoteRef)
        }

        print("Fetch complete.")
        for ref in updatedRefs.sorted() {
            print("  \(ref)")
        }
        print("")
        print("To inspect:  git log refs/remotes/bltgit/main")
        print("To merge:    git merge refs/remotes/bltgit/main")
    }

    /// Push local commits to the remote.
    func push() async throws {
        // Read refs to see what server has.
        let serverRefs = try await readServerRefs()

        let localRefs = try repo.allRefs()
        guard let headHash = localRefs["HEAD"] else {
            print("Nothing to push (no HEAD).")
            return
        }

        let branchName = "refs/heads/main" // TODO: resolve actual HEAD symbolic ref
        let serverHash = serverRefs[branchName] ?? "0000000000000000000000000000000000000000"

        if serverHash == headHash {
            print("Everything up to date.")
            try await bridge.write(data: PktLine.flush)
            return
        }

        // Send the push command.
        let cap = " report-status side-band-64k agent=bltgit/1.0"
        try await bridge.write(data: PktLine.encode("\(serverHash) \(headHash) \(branchName)\0\(cap)\n"))
        try await bridge.write(data: PktLine.flush)

        // Generate and send the packfile.
        var haves: [String] = []
        if serverHash != "0000000000000000000000000000000000000000" {
            haves.append(serverHash)
        }

        let packData = try repo.generatePack(wants: [headHash], haves: haves)
        print("Sending pack (\(packData.count) bytes)...")
        let chunker = ChunkedTransfer(bridge: bridge)
        let reporter = ProgressReporter(totalBytes: packData.count)
        chunker.onProgress = { bytes in reporter.update(bytesDiff: bytes) }
        try await chunker.send(data: packData)
        reporter.finish()

        // Read the server's status report.
        while true {
            guard let lineData = try await PktLine.decodeFrom(stream: bridge) else { break }
            let line = String(data: lineData, encoding: .utf8) ?? ""
            print("Server: \(line.trimmingCharacters(in: .newlines))")
        }

        print("Push complete.")
    }

    /// Print the remote's recent commit history without downloading any data locally.
    func log() async throws {
        // Consume the server's ref advertisement — not needed for log.
        while let _ = try await PktLine.decodeFrom(stream: bridge) {}

        try await bridge.write(data: PktLine.encode("bltgit-log\n"))
        try await bridge.write(data: PktLine.flush)

        var count = 0
        while let lineData = try await PktLine.decodeFrom(stream: bridge) {
            let line = String(data: lineData, encoding: .utf8) ?? ""
            let trimmed = line.trimmingCharacters(in: .newlines)
            if trimmed.hasPrefix("error:") {
                print(trimmed)
                return
            }
            print(trimmed)
            count += 1
        }

        if count == 0 {
            print("No commits on remote.")
        }
    }

    /// Compare local refs with the remote's refs and print a summary without transferring any data.
    func status(deviceName: String) async throws {
        // Read the server's ref advertisement.
        let serverRefs = try await readServerRefs()

        // Close the protocol cleanly:
        //   First flush  → ends the "wants" phase  (server exits phase-1 loop)
        //   Second flush → ends the "haves" phase  (server exits phase-2 loop, sees wants==[] → returns)
        try await bridge.write(data: PktLine.flush)
        try await bridge.write(data: PktLine.flush)

        let localRefs = try repo.allRefs()

        // Classify every branch ref.
        struct BranchLine {
            let branch: String   // short name, e.g. "main"
            let label: String    // human-readable status
        }
        var lines: [BranchLine] = []

        // Branches the remote has.
        for (name, remoteHash) in serverRefs.sorted(by: { $0.key < $1.key }) {
            guard name.hasPrefix("refs/heads/") else { continue }
            let branch = String(name.dropFirst("refs/heads/".count))

            guard let localHash = localRefs[name] else {
                lines.append(.init(branch: branch, label: "remote only (not cloned locally)"))
                continue
            }

            if localHash == remoteHash {
                lines.append(.init(branch: branch, label: "up to date"))
                continue
            }

            // Both hashes differ. Use ancestry to classify.
            let remoteInLocal = repo.hasCommit(remoteHash)

            if remoteInLocal {
                let weAreAhead  = repo.isAncestor(remoteHash, of: localHash)
                let weAreBehind = repo.isAncestor(localHash,  of: remoteHash)

                if weAreAhead && !weAreBehind {
                    let n = repo.revListCount(from: remoteHash, to: localHash)
                    lines.append(.init(branch: branch, label: "\(n) commit\(n == 1 ? "" : "s") ahead"))
                } else if weAreBehind && !weAreAhead {
                    let n = repo.revListCount(from: localHash, to: remoteHash)
                    lines.append(.init(branch: branch, label: "\(n) commit\(n == 1 ? "" : "s") behind"))
                } else {
                    let ahead  = repo.revListCount(from: remoteHash, to: localHash)
                    let behind = repo.revListCount(from: localHash,  to: remoteHash)
                    lines.append(.init(branch: branch, label: "diverged (\(ahead) ahead, \(behind) behind)"))
                }
            } else {
                // Remote hash not local — they have commits we have never fetched.
                lines.append(.init(branch: branch, label: "remote has new commits (run bltgit fetch \(deviceName))"))
            }
        }

        // Branches that only exist locally.
        for name in localRefs.keys.sorted() where name.hasPrefix("refs/heads/") && serverRefs[name] == nil {
            let branch = String(name.dropFirst("refs/heads/".count))
            lines.append(.init(branch: branch, label: "local only"))
        }

        if lines.isEmpty {
            print("No branches found.")
            return
        }

        // Align the branch column.
        let maxLen = lines.map { $0.branch.count }.max() ?? 0
        for l in lines.sorted(by: { $0.branch < $1.branch }) {
            let pad = String(repeating: " ", count: maxLen - l.branch.count + 2)
            print("  \(l.branch)\(pad)\(l.label)")
        }
    }

    // MARK: - Private helpers

    /// Reads the server's initial ref advertisement and returns a `[refName: hash]` map.
    private func readServerRefs() async throws -> [String: String] {
        var refs: [String: String] = [:]
        while true {
            guard let line = try await PktLine.decodeFrom(stream: bridge) else { break }
            let str = String(data: line, encoding: .utf8) ?? ""
            if let spaceIndex = str.firstIndex(of: " ") {
                let hash = String(str[..<spaceIndex])
                let rest  = String(str[str.index(after: spaceIndex)...])
                let name  = rest.components(separatedBy: "\0")[0]
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                if name != "capabilities^{}" {
                    refs[name] = hash
                }
            }
        }
        return refs
    }

    /// Performs the want/have negotiation and receives the packfile.
    ///
    /// Returns `nil` if the local repo is already up to date (nothing to fetch).
    /// Otherwise returns the server's refs and the downloaded pack data.
    private func negotiateAndReceivePack() async throws -> (serverRefs: [String: String], packData: Data)? {
        let serverRefs = try await readServerRefs()
        let localRefs  = try repo.allRefs()

        // Only ask for hashes we don't already have.
        let wants = Set(
            serverRefs.compactMap { name, hash in
                localRefs[name] != hash ? hash : nil
            }
        )

        if wants.isEmpty {
            // Signal to the server that we need nothing.
            try await bridge.write(data: PktLine.flush)
            return nil
        }

        let haves = try repo.recentCommits()

        // Send wants.
        var first = true
        for want in wants {
            let cap = first ? " multi_ack side-band-64k ofs-delta agent=bltgit/1.0" : ""
            try await bridge.write(data: PktLine.encode("want \(want)\(cap)\n"))
            first = false
        }
        try await bridge.write(data: PktLine.flush)

        // Send haves then done.
        for have in haves {
            try await bridge.write(data: PktLine.encode("have \(have)\n"))
        }
        try await bridge.write(data: PktLine.encode("done\n"))

        // Discard NAK — server sends this to confirm it understood "done".
        _ = try await PktLine.decodeFrom(stream: bridge)

        // Receive the packfile with a live progress bar.
        print("Receiving pack...")
        let chunker = ChunkedTransfer(bridge: bridge)
        let reporter = ProgressReporter(totalBytes: nil)
        chunker.onProgress = { bytes in reporter.update(bytesDiff: bytes) }
        let packData = try await chunker.receive()
        reporter.finish()

        return (serverRefs, packData)
    }
}
