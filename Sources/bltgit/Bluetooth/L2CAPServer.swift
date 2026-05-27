import Foundation
import CoreBluetooth

class L2CAPServer {
    func handle(channel: CBL2CAPChannel) -> StreamBridge {
        let bridge = StreamBridge(inputStream: channel.inputStream, outputStream: channel.outputStream)
        bridge.start()
        return bridge
    }
}
