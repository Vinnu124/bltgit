import Foundation
import CommonCrypto

class PairingManager: @unchecked Sendable {
    static let shared = PairingManager()
    
    func performPairing(bridge: StreamBridge, deviceName: String, identifier: UUID, isServer: Bool) async throws -> Bool {
        let isTrustedLocally = TrustStore.shared.isTrusted(identifier: identifier)
        
        var pin: String = ""
        
        if isServer {
            pin = String(format: "%06d", Int.random(in: 0..<1000000))
            print("\nPairing request from \(deviceName).")
            print("Please verify they see the PIN: \(pin)")
        } else {
            print("\nConnecting to \(deviceName)...")
        }
        
        // Mutual trust handshake to prevent desync
        try await bridge.write(data: Data([isTrustedLocally ? 1 : 0]))
        let peerResponse = try await bridge.read(count: 1)
        let isTrustedByPeer = peerResponse.first == 1
        
        if isTrustedLocally && isTrustedByPeer {
            print("Mutual trust established with \(deviceName). Skipping PIN.")
            return true
        } else if isTrustedLocally {
            print("Trust desync detected. Resetting trust for \(deviceName).")
            TrustStore.shared.removeDevice(identifier: identifier)
        }
        
        if isServer {
            // Server sends hash first
            try await bridge.write(data: hash(pin))
            
            // Server reads client response (1 byte, 1 for yes, 0 for no)
            let response = try await bridge.read(count: 1)
            let approved = response.first == 1
            
            if approved {
                print("Client confirmed pairing.")
                print("Do you confirm? (y/n)")
                let userApprove = (await asyncReadLine())?.lowercased() == "y"
                try await bridge.write(data: Data([userApprove ? 1 : 0]))
                if userApprove {
                    TrustStore.shared.addDevice(identifier: identifier, name: deviceName)
                    return true
                }
            }
            return false
        } else {
            // Client reads server hash
            let serverHash = try await bridge.read(count: 32)
            
            print("\nConnecting to \(deviceName) for the first time.")
            print("Enter the PIN shown on \(deviceName):")
            
            guard let enteredPin = await asyncReadLine() else { return false }
            
            let ourHash = hash(enteredPin)
            if ourHash == serverHash {
                try await bridge.write(data: Data([1])) // Yes
                
                print("Waiting for server confirmation...")
                let serverResponse = try await bridge.read(count: 1)
                if serverResponse.first == 1 {
                    print("Pairing successful.")
                    TrustStore.shared.addDevice(identifier: identifier, name: deviceName)
                    return true
                } else {
                    print("Server rejected pairing.")
                    return false
                }
            } else {
                try await bridge.write(data: Data([0])) // No
                print("Incorrect PIN.")
                return false
            }
        }
    }
    
    /// Reads a line from stdin without blocking a cooperative-pool thread.
    /// The actual blocking read is dispatched to a global utility queue.
    private func asyncReadLine() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: readLine())
            }
        }
    }

    private func hash(_ string: String) -> Data {
        guard let data = string.data(using: .utf8) else { return Data() }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}
