import Foundation

enum StreamError: Error {
    case timeout
    case closed
    case unknown
}

class StreamBridge: NSObject, StreamDelegate {
    private let inputStream: InputStream
    private let outputStream: OutputStream
    private var buffer = Data()
    
    private var inputContinuation: CheckedContinuation<Void, Never>?
    private var isClosed = false
    
    init(inputStream: InputStream, outputStream: OutputStream) {
        self.inputStream = inputStream
        self.outputStream = outputStream
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
        isClosed = true
        inputStream.close()
        outputStream.close()
        inputContinuation?.resume()
        inputContinuation = nil
    }
    
    func read(count: Int) async throws -> Data {
        while buffer.count < count {
            if isClosed && buffer.count < count {
                throw StreamError.closed
            }
            await withCheckedContinuation { continuation in
                self.inputContinuation = continuation
            }
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return result
    }
    
    func readAvailable() -> Data {
        let result = buffer
        buffer.removeAll()
        return result
    }
    
    func write(data: Data) async throws {
        var remaining = data
        while !remaining.isEmpty {
            if isClosed { throw StreamError.closed }
            
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
                buffer.append(tempBuffer, count: bytesRead)
            } else {
                break
            }
        }
        inputContinuation?.resume()
        inputContinuation = nil
    }
}
