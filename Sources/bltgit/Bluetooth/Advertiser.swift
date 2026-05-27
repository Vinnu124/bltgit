import Foundation
import CoreBluetooth

class Advertiser: NSObject, CBPeripheralManagerDelegate {
    private var peripheralManager: CBPeripheralManager!
    private let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    private let psmCharacteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5E")
    private let serviceName = "bltgit"
    
    private var isReady = false
    private var shouldAdvertise = false
    private var publishedPSM: CBL2CAPPSM?
    private var psmCharacteristic: CBMutableCharacteristic?
    
    var onChannelOpened: ((CBL2CAPChannel) -> Void)?
    var onError: ((Error) -> Void)?
    
    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    func startAdvertising() {
        shouldAdvertise = true
        if isReady {
            startPublishingAndAdvertising()
        }
    }
    
    func stopAdvertising() {
        shouldAdvertise = false
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        publishedPSM = nil
        psmCharacteristic = nil
    }
    
    private func startPublishingAndAdvertising() {
        guard peripheralManager.state == .poweredOn else { return }
        
        peripheralManager.publishL2CAPChannel(withEncryption: true)
    }
    
    private func beginAdvertisingWithService() {
        guard let psm = publishedPSM else { return }
        
        // Characteristic holding PSM (2 bytes, little-endian)
        var psmValue = CFSwapInt16HostToLittle(psm)
        let psmData = Data(bytes: &psmValue, count: MemoryLayout<UInt16>.size)
        
        psmCharacteristic = CBMutableCharacteristic(
            type: psmCharacteristicUUID,
            properties: [.read],
            value: psmData,
            permissions: [.readable]
        )
        
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [psmCharacteristic!]
        
        peripheralManager.add(service)
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            isReady = true
            if shouldAdvertise {
                startPublishingAndAdvertising()
            }
        case .poweredOff:
            onError?(NSError(domain: "bltgit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is powered off"]))
        case .unauthorized:
            onError?(NSError(domain: "bltgit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is unauthorized"]))
        default:
            break
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error = error {
            onError?(error)
            return
        }
        publishedPSM = PSM
        beginAdvertisingWithService()
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            onError?(error)
            return
        }
        
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: serviceName
        ]
        
        peripheralManager.startAdvertising(advertisementData)
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            onError?(error)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
            onError?(error)
            return
        }
        if let channel = channel {
            onChannelOpened?(channel)
        }
    }
}
