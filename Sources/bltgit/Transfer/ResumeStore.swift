import Foundation

// MARK: - Metadata model

/// Tracks progress of a partially-completed receive operation.
struct ResumeMetadata: Codable {
    /// FNV-1a fingerprint of the pack (size + first 512 bytes). Stable across retries.
    let sessionID: UInt64
    /// Exact number of bytes safely written to the partial file.
    var receivedBytes: Int
    /// The next chunk sequence number we expect to receive (= number of complete chunks so far).
    var nextExpectedSeq: UInt32
}

// MARK: - Store

/// Persists partial transfer state to `~/.config/bltgit/resume/`.
///
/// Files are named by session ID (hex):
///   `<id>.json`    — metadata (receivedBytes, nextExpectedSeq)
///   `<id>.partial` — binary pack data received so far
final class ResumeStore: @unchecked Sendable {

    static let shared = ResumeStore()

    private let dir: URL

    private init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bltgit/resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Path helpers

    private func url(for id: UInt64, ext: String) -> URL {
        dir.appendingPathComponent(String(format: "%016llx.\(ext)", id))
    }

    // MARK: - Metadata

    func loadMeta(sessionID: UInt64) -> ResumeMetadata? {
        guard let data = try? Data(contentsOf: url(for: sessionID, ext: "json")) else { return nil }
        return try? JSONDecoder().decode(ResumeMetadata.self, from: data)
    }

    func saveMeta(_ meta: ResumeMetadata) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        // .atomic ensures the JSON is never half-written.
        try? data.write(to: url(for: meta.sessionID, ext: "json"), options: .atomic)
    }

    // MARK: - Partial data

    /// Load partial data from disk.
    ///
    /// Truncates the file to exactly `safeBytes` to discard any uncommitted tail
    /// (i.e. bytes written to the file after the last metadata save).
    func loadAndTruncatePartial(sessionID: UInt64, safeBytes: Int) -> Data {
        let path = url(for: sessionID, ext: "partial")
        guard FileManager.default.fileExists(atPath: path.path) else { return Data() }

        guard let fh = FileHandle(forUpdatingAtPath: path.path) else { return Data() }
        defer { fh.closeFile() }

        let raw = fh.readDataToEndOfFile()
        let safe = Data(raw.prefix(safeBytes))

        // Truncate so the file length matches what the metadata promises.
        fh.seek(toFileOffset: 0)
        fh.truncateFile(atOffset: UInt64(safe.count))

        return safe
    }

    /// Append a single received chunk to the partial file.
    func appendToPartial(sessionID: UInt64, chunk: Data) {
        let path = url(for: sessionID, ext: "partial")
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: path.path) else { return }
        defer { fh.closeFile() }
        fh.seekToEndOfFile()
        fh.write(chunk)
    }

    // MARK: - Cleanup

    /// Delete all state files for a session (called on success or explicit abandon).
    func clearSession(sessionID: UInt64) {
        try? FileManager.default.removeItem(at: url(for: sessionID, ext: "json"))
        try? FileManager.default.removeItem(at: url(for: sessionID, ext: "partial"))
    }

    // MARK: - Session ID

    /// Stable FNV-1a fingerprint over (totalSize ‖ first 512 bytes).
    /// Same pack content → same ID across separate process runs.
    static func computeSessionID(for data: Data) -> UInt64 {
        let prime: UInt64  = 1_099_511_628_211
        var hash:  UInt64  = 14_695_981_039_346_656_037

        // Mix in total size.
        var size = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &size) { buf in
            for byte in buf { hash = (hash ^ UInt64(byte)) &* prime }
        }

        // Mix in content prefix (fast; stable for same pack objects).
        for byte in data.prefix(512) {
            hash = (hash ^ UInt64(byte)) &* prime
        }

        return hash
    }
}
