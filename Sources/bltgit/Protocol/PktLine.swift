import Foundation

class PktLine {
    static let flush = Data([0x30, 0x30, 0x30, 0x30]) // "0000"
    
    static func encode(_ string: String) -> Data {
        guard let data = string.data(using: .utf8) else { return Data() }
        return encode(data)
    }
    
    static func encode(_ data: Data) -> Data {
        let length = data.count + 4
        let hexLength = String(format: "%04x", length).data(using: .utf8)!
        var pktData = Data()
        pktData.append(hexLength)
        pktData.append(data)
        return pktData
    }
    
    static func decodeFrom(stream: StreamBridge) async throws -> Data? {
        let lengthData = try await stream.read(count: 4)
        guard let lengthString = String(data: lengthData, encoding: .utf8),
              let length = Int(lengthString, radix: 16) else {
            throw NSError(domain: "bltgit", code: 11, userInfo: [NSLocalizedDescriptionKey: "Invalid pkt-line length prefix"])
        }
        
        if length == 0 {
            return nil // Flush packet
        }
        
        if length <= 4 {
             throw NSError(domain: "bltgit", code: 12, userInfo: [NSLocalizedDescriptionKey: "pkt-line length too short"])
        }
        
        return try await stream.read(count: length - 4)
    }
}
