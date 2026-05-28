import Foundation
import CoreBluetooth

enum StreamError: Error {
    case timeout
    case closed
    case unknown
}

class StreamBridge: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel?
    private let inputStream: InputStream
    private let outputStream: OutputStream
    private var buffer = Data()
    
    private let lock = NSLock()
    private var isClosed = false
    
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
        lock.lock()
        isClosed = true
        lock.unlock()
        inputStream.close()
        outputStream.close()
    }
    
    func read(count: Int) async throws -> Data {
        while true {
            lock.lock()
            if buffer.count >= count {
                let result = buffer.prefix(count)
                buffer.removeFirst(count)
                lock.unlock()
                return result
            }
            if isClosed {
                lock.unlock()
                throw StreamError.closed
            }
            lock.unlock()
            
            // Poll for data. Solves all race conditions safely.
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
    
    func readAvailable() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let result = buffer
        buffer.removeAll()
        return result
    }
    
    func write(data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            lock.lock()
            let closed = isClosed
            lock.unlock()
            if closed { throw StreamError.closed }
            
            if outputStream.hasSpaceAvailable {
                let bytesWritten = remaining.withUnsafeBytes { ptr in
                    outputStream.write(ptr.bindMemory(to: UInt8.self).baseAddress!, maxLength: remaining.count)
                }
                
                if bytesWritten < 0 {
                    throw StreamError.unknown
                } else if bytesWritten == 0 {
                    // Try again
                    try await Task.sleep(nanoseconds: 10_000_000)
                } else {
                    remaining.removeFirst(bytesWritten)
                }
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            if aStream === inputStream {
                readFromStream()
            }
        case .endEncountered, .errorOccurred:
            close()
        default:
            break
        }
    }
    
    private func readFromStream() {
        let bufferSize = 1024
        var tempBuffer = [UInt8](repeating: 0, count: bufferSize)
        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(&tempBuffer, maxLength: bufferSize)
            if bytesRead > 0 {
                lock.lock()
                buffer.append(tempBuffer, count: bytesRead)
                lock.unlock()
            } else {
                break
            }
        }
    }
}
