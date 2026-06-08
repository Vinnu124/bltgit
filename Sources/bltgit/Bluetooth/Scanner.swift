import Foundation
import CoreBluetooth

// CBPeripheral is an ObjC class; we access it only on the main thread
// (CB delegate callbacks), so @unchecked Sendable is safe here.
struct DiscoveredDevice: @unchecked Sendable {
    let name: String
    let peripheral: CBPeripheral
    let rssi: Int
}

class Scanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var centralManager: CBCentralManager!
    private let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    
    private var isReady = false
    private var shouldScan = false
    private var scanTask: Task<[DiscoveredDevice], Error>?
    
    private var discoveredDevices: [UUID: DiscoveredDevice] = [:]
    private var scanContinuation: CheckedContinuation<[DiscoveredDevice], Error>?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func scan(timeout: TimeInterval = 10.0) async throws -> [DiscoveredDevice] {
        shouldScan = true
        discoveredDevices.removeAll()
        
        if centralManager.state == .poweredOff {
            throw NSError(domain: "bltgit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is powered off"])
        }
        if centralManager.state == .unauthorized {
            throw NSError(domain: "bltgit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is unauthorized"])
        }
        
        if isReady {
            startScanning()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.scanContinuation = continuation

            // Run on @MainActor so the post-sleep mutations happen on the same
            // thread as CBCentralManager's delegate callbacks — preventing data
            // races on `scanContinuation` and `discoveredDevices`.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.stopScanning()
                if let cont = self.scanContinuation {
                    self.scanContinuation = nil
                    cont.resume(returning: Array(self.discoveredDevices.values))
                }
            }
        }
    }
    
    private func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
    
    private func stopScanning() {
        shouldScan = false
        centralManager.stopScan()
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isReady = true
            if shouldScan {
                startScanning()
            }
        case .poweredOff:
            scanContinuation?.resume(throwing: NSError(domain: "bltgit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is powered off"]))
            scanContinuation = nil
        case .unauthorized:
            scanContinuation?.resume(throwing: NSError(domain: "bltgit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is unauthorized"]))
            scanContinuation = nil
        default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown Device"
        let device = DiscoveredDevice(name: name, peripheral: peripheral, rssi: RSSI.intValue)
        discoveredDevices[peripheral.identifier] = device
    }
}
