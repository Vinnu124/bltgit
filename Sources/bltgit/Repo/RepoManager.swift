import Foundation

class RepoManager {
    let repoURL: URL

    init(path: String) throws {
        self.repoURL = URL(fileURLWithPath: path)
    }

    static func initialize(at path: String) throws -> RepoManager {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = url
        try process.run()
        process.waitUntilExit()
        return try RepoManager(path: path)
    }

    // MARK: - Refs

    /// Returns all refs in the repository.
    /// Returns an empty dictionary for a brand-new repo (git show-ref exits 1 when
    /// there are no refs yet, which is expected and not an error).
    func allRefs() throws -> [String: String] {
        var refs: [String: String] = [:]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["show-ref"]
        process.currentDirectoryURL = repoURL

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()  // suppress stderr for expected "no refs" case

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let string = String(data: data, encoding: .utf8) {
                let lines = string.components(separatedBy: .newlines).filter { !$0.isEmpty }
                for line in lines {
                    let parts = line.components(separatedBy: " ")
                    if parts.count == 2 {
                        refs[parts[1]] = parts[0]
                    }
                }
            }
        } catch {
            // git may not be runnable — propagate the error.
            throw error
        }

        return refs
    }

    // MARK: - Commits

    func recentCommits() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-list", "--max-count=32", "HEAD"]
        process.currentDirectoryURL = repoURL

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()  // HEAD may not exist in empty repos

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let string = String(data: data, encoding: .utf8) {
                return string.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }
        } catch {}
        return []
    }

    /// Returns the last `maxCount` commits formatted as one human-readable line each.
    /// Format: "<short-hash>  <author>  <relative-date>  <subject>"
    func gitLog(maxCount: Int = 20) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // %h  = abbreviated hash, %an = author name, %ar = relative date, %s = subject
        process.arguments = [
            "log",
            "--max-count=\(maxCount)",
            "--pretty=format:%h  %an  %ar  %s",
            "HEAD"
        ]
        process.currentDirectoryURL = repoURL

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let string = String(data: data, encoding: .utf8) {
                return string.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }
        } catch {}
        return []
    }

    // MARK: - Pack generation

    func generatePack(wants: [String], haves: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["pack-objects", "--stdout", "--revs",
                             "--delta-base-offset", "-q"]
        process.currentDirectoryURL = repoURL

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Build the revision list (always small — just commit hashes).
        var inputString = ""
        for want in wants { inputString += "\(want)\n" }
        for have in haves { inputString += "^\(have)\n" }

        try process.run()
        // Input is commit hashes only — well under the pipe buffer limit, safe to write inline.
        inPipe.fileHandleForWriting.write(inputString.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw NSError(domain: "bltgit", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: "git pack-objects failed: \(msg)"])
        }

        return data
    }

    // MARK: - Pack application

    func applyPack(data: Data) throws {
        guard !data.isEmpty else {
            throw NSError(domain: "bltgit", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: "Received empty pack data"])
        }
        print("Applying pack: \(data.count) bytes...")

        let fm = FileManager.default

        // Write the pack to a temp file — avoids stdin pipe races on large packs.
        let tempPack = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bltgit-\(UUID().uuidString).pack")
        try data.write(to: tempPack)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // index-pack <file> creates <file>.idx alongside the pack file.
        process.arguments = ["index-pack", tempPack.path]
        process.currentDirectoryURL = repoURL

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            try? fm.removeItem(at: tempPack)
            try? fm.removeItem(at: tempPack.deletingPathExtension().appendingPathExtension("idx"))
            throw NSError(domain: "bltgit", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: "git index-pack failed: \(msg)"])
        }

        // Capture the SHA from stdout so we can give the files canonical names.
        let sha = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Move .pack and .idx into the repo's pack directory.
        let packDir = repoURL.appendingPathComponent(".git/objects/pack")
        try fm.createDirectory(at: packDir, withIntermediateDirectories: true)

        let baseName = sha.count == 40 ? "pack-\(sha)" : "pack-bltgit-\(UUID().uuidString)"
        let tempIdx = tempPack.deletingPathExtension().appendingPathExtension("idx")
        let destPack = packDir.appendingPathComponent("\(baseName).pack")
        let destIdx  = packDir.appendingPathComponent("\(baseName).idx")

        do {
            try fm.moveItem(at: tempPack, to: destPack)
            try fm.moveItem(at: tempIdx,  to: destIdx)
        } catch {
            try? fm.removeItem(at: tempPack)
            try? fm.removeItem(at: tempIdx)
            throw error
        }

        print("Pack indexed and stored: \(baseName)")
    }

    // MARK: - Ref updates

    func updateRef(name: String, hash: String) throws {
        print("Setting ref \(name) → \(hash)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["update-ref", name, hash]
        process.currentDirectoryURL = repoURL

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            print("  ✗ updateRef failed: \(msg)")
            throw NSError(domain: "bltgit", code: 25,
                          userInfo: [NSLocalizedDescriptionKey: "git update-ref failed: \(msg)"])
        }
        print("  ✓ ref set")
    }

    // MARK: - HEAD management

    /// Points HEAD at the given full ref name (e.g. "refs/heads/main").
    func setHead(to refName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["symbolic-ref", "HEAD", refName]
        process.currentDirectoryURL = repoURL

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()
        // Non-zero exit is non-fatal: if the ref is detached it just won't be set
    }

    // MARK: - Working-tree checkout

    func checkout() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // `reset --hard HEAD` rebuilds both the index and working tree from scratch.
        // More reliable than `checkout -f HEAD` after index-pack on a fresh repo.
        process.arguments = ["reset", "--hard", "HEAD"]
        process.currentDirectoryURL = repoURL

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                print("Checkout failed: \(msg)")
            }
        } catch {
            print("Checkout failed: \(error)")
        }
    }
}
