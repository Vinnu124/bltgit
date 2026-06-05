import Foundation

class ChunkedTransfer {
    let bridge: StreamBridge
    private let chunkSize = 60 * 1024 // 60 KB

    /// Optional progress callback — called with the number of bytes just confirmed sent/received.
    var onProgress: ((Int) -> Void)?

    init(bridge: StreamBridge) {
        self.bridge = bridge
    }

    func send(data: Data) async throws {
        var offset = 0
        var sequenceNumber: UInt32 = 0
        
        while offset < data.count {
            let length = min(chunkSize, data.count - offset)
            let chunkData = data[offset..<offset+length]
            
            try await sendWithRetry(sequenceNumber: sequenceNumber, chunkData: chunkData)
            
            offset += length
            sequenceNumber += 1
            onProgress?(length) // ← report bytes confirmed by ACK
        }

        // End-of-transfer sentinel (length = 0)
        try await sendWithRetry(sequenceNumber: sequenceNumber, chunkData: Data())
    }

    private func sendWithRetry(sequenceNumber: UInt32, chunkData: Data) async throws {
        let maxRetries = 3
        var retries = 0

        while retries < maxRetries {
            do {
                var chunk = Data()
                var seq = CFSwapInt32HostToBig(sequenceNumber)
                var len = CFSwapInt32HostToBig(UInt32(chunkData.count))

                chunk.append(Data(bytes: &seq, count: 4))
                chunk.append(Data(bytes: &len, count: 4))
                chunk.append(chunkData)

                try await bridge.write(data: chunk)

                // Wait for ACK
                let ack = try await bridge.read(count: 5) // 4 bytes seq, 1 byte status

                let ackSeqBytes = ack.prefix(4)
                let ackSeq = ackSeqBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
                let status = ack.dropFirst(4).first ?? 0

                if ackSeq == sequenceNumber && status == 1 {
                    return // Success
                }
            } catch let streamErr as StreamError where streamErr == .closed {
                // Connection is gone — retrying won't help.
                throw streamErr
            } catch {
                print("\nError sending chunk \(sequenceNumber): \(error). Retrying...")
            }
            retries += 1
        }
        throw NSError(domain: "bltgit", code: 10,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to send chunk after max retries"])
    }

    func receive() async throws -> Data {
        var result = Data()
        var expectedSeq: UInt32 = 0
        
        while true {
            let header = try await bridge.read(count: 8)
            let seqBytes = header.prefix(4)
            let lenBytes = header.dropFirst(4).prefix(4)

            let seq = seqBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
            let len = lenBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian

            if len == 0 {
                // End of transfer
                try await sendAck(sequenceNumber: seq, status: 1)
                break
            }
            
            let chunkData = try await bridge.read(count: Int(len))
            
            if seq == expectedSeq {
                result.append(chunkData)
                try await sendAck(sequenceNumber: seq, status: 1)
                onProgress?(Int(len)) // ← report bytes received and ACK'd
                expectedSeq += 1
            } else if seq < expectedSeq {
                // Already received; ACK lost — resend ACK.
                try await sendAck(sequenceNumber: seq, status: 1)
            } else {
                // Out of order — NACK.
                try await sendAck(sequenceNumber: seq, status: 0)
            }
        }

        return result
    }

    private func sendAck(sequenceNumber: UInt32, status: UInt8) async throws {
        var ack = Data()
        var seq = CFSwapInt32HostToBig(sequenceNumber)
        ack.append(Data(bytes: &seq, count: 4))
        ack.append(status)
        try await bridge.write(data: ack)
    }
}
