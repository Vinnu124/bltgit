import Foundation
import CommonCrypto

class PairingManager {
    static let shared = PairingManager()
    
    func performPairing(bridge: StreamBridge, deviceName: String, identifier: UUID, isServer: Bool) async throws -> Bool {
        if TrustStore.shared.isTrusted(identifier: identifier) {
            return true
        }
        
        let pin: String
        let receivedHash: Data
        
        if isServer {
            pin = String(format: "%06d", Int.random(in: 0..<1000000))
            print("\nPairing request from \(deviceName).")
            print("Please verify they see the PIN: \(pin)")
            
            // Server sends hash first
            try await bridge.write(data: hash(pin))
            
            // Server reads client response (1 byte, 1 for yes, 0 for no)
            let response = try await bridge.read(count: 1)
            let approved = response[0] == 1
            
            if approved {
                print("Client confirmed pairing.")
                print("Do you confirm? (y/n)")
                let userApprove = readLine()?.lowercased() == "y"
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
            
            guard let enteredPin = readLine() else { return false }
            
            let ourHash = hash(enteredPin)
            if ourHash == serverHash {
                try await bridge.write(data: Data([1])) // Yes
                
                print("Waiting for server confirmation...")
                let serverResponse = try await bridge.read(count: 1)
                if serverResponse[0] == 1 {
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
    
    private func hash(_ string: String) -> Data {
        guard let data = string.data(using: .utf8) else { return Data() }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}
