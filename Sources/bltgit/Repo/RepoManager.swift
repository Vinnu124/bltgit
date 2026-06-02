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

    // MARK: - Pack generation

    func generatePack(wants: [String], haves: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["pack-objects", "--stdout", "--revs", "--thin",
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["index-pack", "--stdin", "--fix-thin", "-q"]
        process.currentDirectoryURL = repoURL

        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardError = errPipe

        try process.run()

        // Write on a background thread to prevent deadlocking when the pack
        // data exceeds the kernel pipe buffer (≈ 65 KB on macOS).  If we
        // wrote synchronously, the main thread could block on write() while
        // git is trying to write its output and has nobody reading it.
        let writer = DispatchQueue(label: "bltgit.applypack.write")
        writer.async {
            inPipe.fileHandleForWriting.write(data)
            inPipe.fileHandleForWriting.closeFile()
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw NSError(domain: "bltgit", code: 24,
                          userInfo: [NSLocalizedDescriptionKey: "git index-pack failed: \(msg)"])
        }
    }

    // MARK: - Ref updates

    func updateRef(name: String, hash: String) throws {
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
            throw NSError(domain: "bltgit", code: 25,
                          userInfo: [NSLocalizedDescriptionKey: "git update-ref failed: \(msg)"])
        }
    }

    // MARK: - Working-tree checkout

    func checkout() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["checkout", "-f", "HEAD"]
        process.currentDirectoryURL = repoURL

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Checkout failed: \(error)")
        }
    }
}
