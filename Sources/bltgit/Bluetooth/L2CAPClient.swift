import Foundation
import CoreBluetooth

class L2CAPClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    private let psmCharacteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5E")
    
    private var connectContinuation: CheckedContinuation<StreamBridge, Error>?
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func connect(to device: DiscoveredDevice) async throws -> StreamBridge {
        guard centralManager.state == .poweredOn else {
            throw NSError(domain: "bltgit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth not powered on"])
        }
        
        targetPeripheral = device.peripheral
        targetPeripheral?.delegate = self
        
        return try await withCheckedThrowingContinuation { continuation in
            self.connectContinuation = continuation
            centralManager.connect(device.peripheral, options: nil)
            
            Task {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                if self.connectContinuation != nil {
                    self.centralManager.cancelPeripheralConnection(device.peripheral)
                    self.connectContinuation?.resume(throwing: NSError(domain: "bltgit", code: 3, userInfo: [NSLocalizedDescriptionKey: "Connection timed out"]))
                    self.connectContinuation = nil
                }
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: error ?? NSError(domain: "bltgit", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to connect"]))
        connectContinuation = nil
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            return
        }
        
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            connectContinuation?.resume(throwing: NSError(domain: "bltgit", code: 5, userInfo: [NSLocalizedDescriptionKey: "Service not found"]))
            connectContinuation = nil
            return
        }
        
        peripheral.discoverCharacteristics([psmCharacteristicUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            return
        }
        
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == psmCharacteristicUUID }) else {
            connectContinuation?.resume(throwing: NSError(domain: "bltgit", code: 6, userInfo: [NSLocalizedDescriptionKey: "PSM characteristic not found"]))
            connectContinuation = nil
            return
        }
        
        peripheral.readValue(for: characteristic)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            return
        }
        
        guard let data = characteristic.value, data.count >= MemoryLayout<UInt16>.size else {
            connectContinuation?.resume(throwing: NSError(domain: "bltgit", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid PSM data"]))
            connectContinuation = nil
            return
        }
        
        let psmValue = data.withUnsafeBytes { $0.load(as: UInt16.self) }
        let psm = CFSwapInt16LittleToHost(psmValue)
        
        peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
            connectContinuation?.resume(throwing: error)
            connectContinuation = nil
            return
        }
        
        guard let channel = channel else {
            connectContinuation?.resume(throwing: NSError(domain: "bltgit", code: 8, userInfo: [NSLocalizedDescriptionKey: "Channel failed to open"]))
            connectContinuation = nil
            return
        }
        
        let bridge = StreamBridge(inputStream: channel.inputStream, outputStream: channel.outputStream)
        bridge.start()
        
        connectContinuation?.resume(returning: bridge)
        connectContinuation = nil
    }
}
