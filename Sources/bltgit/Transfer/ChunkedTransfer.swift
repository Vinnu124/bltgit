import Foundation

// MARK: - Wire protocol for one transfer session
//
// Before any chunks the sender writes a 16-byte session header:
//   [8 bytes] sessionID  (UInt64, big-endian) — FNV-1a fingerprint of the pack
//   [4 bytes] totalChunks (UInt32, big-endian)
//   [4 bytes] totalBytes  (UInt32, big-endian)
//
// The receiver replies with a 4-byte resume point:
//   [4 bytes] resumeFromSeq (UInt32, big-endian) — 0 = fresh start
//
// Then normal chunk frames follow, starting at resumeFromSeq:
//   [4 bytes] sequenceNumber (UInt32, big-endian)
//   [4 bytes] length         (UInt32, big-endian) — 0 means end-of-transfer
//   [length bytes] payload
//
// ACK (receiver → sender):
//   [4 bytes] sequenceNumber (UInt32, big-endian)
//   [1 byte]  status         — 1 = OK, 0 = NACK (resend)

class ChunkedTransfer {
    let bridge: StreamBridge
    private let chunkSize = 60 * 1024 // 60 KB

    // MARK: Callbacks

    /// Called with the number of bytes just confirmed sent/received.
    var onProgress: ((Int) -> Void)?

    /// Called once the session header has been exchanged.
    /// Provides (sessionID, totalBytes, resumingFromSeq) so callers can
    /// configure progress bars with accurate totals and starting offsets.
    var onSessionStart: ((UInt64, Int, UInt32) -> Void)?

    init(bridge: StreamBridge) {
        self.bridge = bridge
    }

    // MARK: - Send

    func send(data: Data) async throws {
        let sessionID   = ResumeStore.computeSessionID(for: data)
        let totalChunks = UInt32((data.count + chunkSize - 1) / chunkSize)
        let totalBytes  = UInt32(data.count)

        // ── Session header ──────────────────────────────────────────────────
        var header = Data(capacity: 16)
        header.appendBigEndian(sessionID)
        header.appendBigEndian(totalChunks)
        header.appendBigEndian(totalBytes)
        try await bridge.write(data: header)

        // ── Read receiver's resume point ────────────────────────────────────
        let replyData   = try await bridge.read(count: 4)
        let resumeFrom  = replyData.loadBigEndian(UInt32.self, at: 0)

        onSessionStart?(sessionID, data.count, resumeFrom)

        if resumeFrom > 0 {
            let skippedBytes = Int(resumeFrom) * chunkSize
            print("Resuming from chunk \(resumeFrom)/\(totalChunks) (\(skippedBytes) bytes already delivered)...")
            // Pre-advance the progress bar so it starts at the right position.
            onProgress?(skippedBytes)
        }

        // ── Send chunks from resumeFrom onwards ────────────────────────────
        var seq    = resumeFrom
        var offset = Int(resumeFrom) * chunkSize

        while offset < data.count {
            let length    = min(chunkSize, data.count - offset)
            let chunkData = data[offset ..< offset + length]
            try await sendWithRetry(sequenceNumber: seq, chunkData: chunkData)
            offset += length
            seq    += 1
            onProgress?(length)
        }

        // End-of-transfer sentinel (length = 0).
        try await sendWithRetry(sequenceNumber: seq, chunkData: Data())
    }

    // MARK: - Receive

    func receive() async throws -> Data {
        // ── Read session header ─────────────────────────────────────────────
        let hdr        = try await bridge.read(count: 16)
        let sessionID  = hdr.loadBigEndian(UInt64.self, at: 0)
        let totalChunks = hdr.loadBigEndian(UInt32.self, at: 8)
        let totalBytes  = hdr.loadBigEndian(UInt32.self, at: 12)

        // ── Check for existing partial state ────────────────────────────────
        let store = ResumeStore.shared
        var meta: ResumeMetadata
        var accumulated: Data

        if var existing = store.loadMeta(sessionID: sessionID) {
            // Resume: truncate the partial file to the last *committed* byte
            // to discard any tail written after the last metadata save.
            accumulated        = store.loadAndTruncatePartial(sessionID: sessionID,
                                                              safeBytes: existing.receivedBytes)
            existing.receivedBytes = accumulated.count      // sync after truncation
            meta               = existing
            print("Resuming interrupted transfer from chunk \(meta.nextExpectedSeq)/\(totalChunks)...")
        } else {
            // Fresh transfer.
            accumulated = Data()
            meta        = ResumeMetadata(sessionID: sessionID,
                                         receivedBytes: 0,
                                         nextExpectedSeq: 0)
        }

        var expectedSeq = meta.nextExpectedSeq

        // ── Reply with resume point ─────────────────────────────────────────
        var resumeReply = Data(capacity: 4)
        resumeReply.appendBigEndian(expectedSeq)
        try await bridge.write(data: resumeReply)

        onSessionStart?(sessionID, Int(totalBytes), expectedSeq)

        // Pre-advance the progress bar if we're resuming mid-stream.
        if accumulated.count > 0 {
            onProgress?(accumulated.count)
        }

        // ── Receive chunks ──────────────────────────────────────────────────
        var saveCounter = 0

        while true {
            let hdrBytes = try await bridge.read(count: 8)
            let seq = hdrBytes.loadBigEndian(UInt32.self, at: 0)
            let len = hdrBytes.loadBigEndian(UInt32.self, at: 4)

            if len == 0 {
                // End-of-transfer sentinel.
                try await sendAck(sequenceNumber: seq, status: 1)
                break
            }

            let chunk = try await bridge.read(count: Int(len))

            if seq == expectedSeq {
                // New in-order chunk.
                accumulated.append(chunk)

                // Persist chunk to disk FIRST, then update metadata.
                // If we crash between the two, the file has an uncommitted tail
                // which will be truncated on the next resume (safe bytes = meta.receivedBytes).
                store.appendToPartial(sessionID: sessionID, chunk: chunk)

                try await sendAck(sequenceNumber: seq, status: 1)
                onProgress?(Int(len))

                expectedSeq         += 1
                meta.receivedBytes   = accumulated.count
                meta.nextExpectedSeq = expectedSeq

                // Save metadata every 8 chunks to bound re-download on resume.
                saveCounter += 1
                if saveCounter >= 8 {
                    store.saveMeta(meta)
                    saveCounter = 0
                }

            } else if seq < expectedSeq {
                // Already received — ACK was lost; resend it.
                try await sendAck(sequenceNumber: seq, status: 1)
            } else {
                // Out-of-order — NACK.
                try await sendAck(sequenceNumber: seq, status: 0)
            }
        }

        // ── Completed successfully — clean up state files ───────────────────
        store.clearSession(sessionID: sessionID)

        return accumulated
    }

    // MARK: - Private helpers

    private func sendWithRetry(sequenceNumber: UInt32, chunkData: Data) async throws {
        let maxRetries = 3
        var retries    = 0

        while retries < maxRetries {
            do {
                var frame = Data(capacity: 8 + chunkData.count)
                frame.appendBigEndian(sequenceNumber)
                frame.appendBigEndian(UInt32(chunkData.count))
                frame.append(chunkData)

                try await bridge.write(data: frame)

                // Wait for ACK: 4-byte seq + 1-byte status.
                let ack    = try await bridge.read(count: 5)
                let ackSeq = ack.loadBigEndian(UInt32.self, at: 0)
                let status = ack[4]

                if ackSeq == sequenceNumber && status == 1 {
                    return // success
                }
            } catch let streamErr as StreamError where streamErr == .closed {
                throw streamErr // connection is gone; no point retrying
            } catch {
                print("\nChunk \(sequenceNumber) error: \(error). Retry \(retries + 1)/\(maxRetries)...")
            }
            retries += 1
        }

        throw NSError(domain: "bltgit", code: 10,
                      userInfo: [NSLocalizedDescriptionKey:
                        "Failed to send chunk \(sequenceNumber) after \(maxRetries) retries"])
    }

    private func sendAck(sequenceNumber: UInt32, status: UInt8) async throws {
        var ack = Data(capacity: 5)
        ack.appendBigEndian(sequenceNumber)
        ack.append(status)
        try await bridge.write(data: ack)
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    func loadBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let raw = self[index(startIndex, offsetBy: offset)...]
        return raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) }.bigEndian
    }
}
