import Foundation
import CoreBluetooth

enum StreamError: Error {
    case timeout
    case closed
    case unknown
    case bufferOverflow
}

/// Maximum bytes allowed in the inbound buffer.
/// Prevents unbounded memory growth if the consumer falls behind the producer.
private let kMaxBufferBytes = 8 * 1024 * 1024  // 8 MB

/// Bridges a CoreBluetooth L2CAP channel's raw streams into an async-friendly
/// read/write interface.
///
/// Design notes:
///   - All mutable state (`buffer`, `isClosed`, `readContinuation`) is
///     protected by `lock.withLock { }`.  Using `withLock` rather than bare
///     `lock()`/`unlock()` calls satisfies the Swift 6 concurrency checker:
///     the compiler can prove the lock is never held across an `await`.
///   - `read(count:)` suspends without busy-polling: it parks a
///     CheckedContinuation that is resumed by the stream delegate the moment
///     new bytes arrive, eliminating unnecessary CPU wake-ups.
///   - At most one concurrent `read()` caller is supported, which is
///     sufficient for the sequential pkt-line / chunked-transfer protocol.
final class StreamBridge: NSObject, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel?
    private let inputStream: InputStream
    private let outputStream: OutputStream

    // All fields below are guarded by `lock`.
    private let lock = NSLock()
    private var buffer = Data()
    private var isClosed = false
    /// At most one reader waits at a time.
    private var readContinuation: CheckedContinuation<Void, Never>?

    init(inputStream: InputStream, outputStream: OutputStream, channel: CBL2CAPChannel? = nil) {
        self.inputStream = inputStream
        self.outputStream = outputStream
        self.channel = channel
        super.init()
        inputStream.delegate = self
        outputStream.delegate = self
    }

    func start() {
        inputStream.schedule(in: .main, forMode: .default)
        outputStream.schedule(in: .main, forMode: .default)
        inputStream.open()
        outputStream.open()
    }

    func close() {
        let pendingCont: CheckedContinuation<Void, Never>? = lock.withLock {
            isClosed = true
            let cont = readContinuation
            readContinuation = nil
            return cont
        }
        inputStream.close()
        outputStream.close()
        // Wake any parked reader so it can observe isClosed and throw .closed.
        pendingCont?.resume()
    }

    // MARK: - Reading

    /// Reads exactly `count` bytes, suspending (without busy-polling) until
    /// they are available.
    func read(count: Int) async throws -> Data {
        while true {
            // Fast path: check buffer + closed status atomically.
            let (fastData, closed): (Data?, Bool) = lock.withLock {
                if buffer.count >= count {
                    let result = Data(buffer.prefix(count))
                    buffer.removeFirst(count)
                    return (result, false)
                }
                return (nil, isClosed)
            }

            if let data = fastData { return data }
            if closed { throw StreamError.closed }

            // Slow path: park until the stream delegate signals more data.
            // Re-check inside the lock before storing the continuation to
            // prevent a lost-wakeup race (data could arrive between the fast
            // path check above and the continuation being registered).
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                var shouldResume = false
                lock.withLock {
                    if buffer.count >= count || isClosed {
                        shouldResume = true
                    } else {
                        readContinuation = cont
                    }
                }
                if shouldResume { cont.resume() }
            }
        }
    }

    /// Returns whatever is currently buffered (may be empty) without waiting.
    func readAvailable() -> Data {
        lock.withLock {
            let result = buffer
            buffer = Data()
            return result
        }
    }

    // MARK: - Writing

    func write(data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            let closed = lock.withLock { isClosed }
            if closed { throw StreamError.closed }

            if outputStream.hasSpaceAvailable {
                let n = remaining.withUnsafeBytes { ptr -> Int in
                    outputStream.write(
                        ptr.bindMemory(to: UInt8.self).baseAddress!,
                        maxLength: remaining.count
                    )
                }
                if n < 0 {
                    throw StreamError.unknown
                } else if n > 0 {
                    remaining.removeFirst(n)
                } else {
                    // Output buffer transiently full — back off briefly.
                    try await Task.sleep(nanoseconds: 5_000_000)  // 5 ms
                }
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable where aStream === inputStream:
            drainInputStream()
        case .endEncountered, .errorOccurred:
            close()
        default:
            break
        }
    }

    // MARK: - Private

    /// Reads all available bytes from the input stream into the buffer and
    /// resumes any parked `read()` continuation.
    /// Called synchronously from the RunLoop on the main thread.
    private func drainInputStream() {
        let chunkSize = 4096
        var temp = [UInt8](repeating: 0, count: chunkSize)
        var signalled = false

        while inputStream.hasBytesAvailable {
            let n = inputStream.read(&temp, maxLength: chunkSize)
            guard n > 0 else { break }

            var overflowed = false
            let cont: CheckedContinuation<Void, Never>? = lock.withLock {
                guard buffer.count + n <= kMaxBufferBytes else {
                    overflowed = true
                    return nil
                }
                buffer.append(temp, count: n)
                // Signal at most once per drain cycle; the reader re-parks
                // itself if it still needs more bytes.
                if !signalled {
                    let c = readContinuation
                    readContinuation = nil
                    return c
                }
                return nil
            }

            if overflowed {
                // Buffer cap exceeded — tear down the connection to prevent OOM.
                close()
                return
            }

            if let c = cont {
                signalled = true
                c.resume()
            }
        }
    }
}
