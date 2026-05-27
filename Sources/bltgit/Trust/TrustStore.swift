import Foundation
import CoreBluetooth

struct TrustedDevice: Codable {
    let identifier: String
    let name: String
    let pairingDate: Date
}

class TrustStore {
    static let shared = TrustStore()
    
    private let storeURL: URL
    private var trustedDevices: [String: TrustedDevice] = [:]
    
    private init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/bltgit")
        storeURL = configDir.appendingPathComponent("trusted_devices.json")
        
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create config directory: \(error)")
        }
        
        load()
    }
    
    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            trustedDevices = try decoder.decode([String: TrustedDevice].self, from: data)
        } catch {
            print("Failed to load trust store: \(error)")
        }
    }
    
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(trustedDevices)
            try data.write(to: storeURL)
        } catch {
            print("Failed to save trust store: \(error)")
        }
    }
    
    func isTrusted(identifier: UUID) -> Bool {
        return trustedDevices[identifier.uuidString] != nil
    }
    
    func addDevice(identifier: UUID, name: String) {
        let device = TrustedDevice(identifier: identifier.uuidString, name: name, pairingDate: Date())
        trustedDevices[identifier.uuidString] = device
        save()
    }
    
    func removeDevice(identifier: UUID) {
        trustedDevices.removeValue(forKey: identifier.uuidString)
        save()
    }
    
    func listDevices() -> [TrustedDevice] {
        return Array(trustedDevices.values).sorted(by: { $0.pairingDate > $1.pairingDate })
    }
}
