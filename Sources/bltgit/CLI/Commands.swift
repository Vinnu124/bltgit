import Foundation
import CoreBluetooth

protocol Command {
    func run() async throws
}

struct ServeCommand: Command {
    func run() async throws {
        let repo = try RepoManager(path: FileManager.default.currentDirectoryPath)
        print("Serving repo at \(repo.repoURL.path)...")
        
        let advertiser = Advertiser()
        advertiser.onChannelOpened = { channel in
             print("New connection from \(channel.peer.identifier)")
             Task {
                 let server = L2CAPServer()
                 let bridge = server.handle(channel: channel)
                 
                 let paired = try await PairingManager.shared.performPairing(bridge: bridge, deviceName: "Unknown", identifier: channel.peer.identifier, isServer: true)
                 if paired {
                     let gitServer = GitServer(bridge: bridge, repo: repo)
                     try await gitServer.pull()
                 } else {
                     print("Pairing failed or rejected.")
                 }
                 bridge.close()
             }
        }
        
        advertiser.onError = { error in
             print("Error: \(error)")
        }
        
        advertiser.startAdvertising()
        
        // Keep the server alive indefinitely without leaking continuations
        try? await Task.sleep(nanoseconds: UInt64.max)
    }
}

struct DiscoverCommand: Command {
    func run() async throws {
        print("Scanning for nearby bltgit devices...")
        let scanner = Scanner()
        let devices = try await scanner.scan()
        if devices.isEmpty {
             print("No bltgit devices found nearby.")
        } else {
             for device in devices {
                  print("Found: \(device.name) (\(device.peripheral.identifier))")
             }
        }
    }
}

struct PullCommand: Command {
    let deviceName: String
    
    func run() async throws {
         let repo = try RepoManager(path: FileManager.default.currentDirectoryPath)
         print("Scanning for \(deviceName)...")
         let scanner = Scanner()
         let devices = try await scanner.scan()
         
         guard let device = devices.first(where: { $0.name == deviceName || $0.peripheral.identifier.uuidString == deviceName }) else {
              print("Device not found. Make sure 'bltgit serve' is running on \(deviceName).")
              return
         }
         
         print("Connecting to \(device.name)...")
         let client = L2CAPClient()
         let bridge = try await client.connect(to: device)
         
         let paired = try await PairingManager.shared.performPairing(bridge: bridge, deviceName: device.name, identifier: device.peripheral.identifier, isServer: false)
         
         if paired {
              let gitClient = GitClient(bridge: bridge, repo: repo)
              try await gitClient.pull()
         } else {
              print("Pairing failed.")
         }
         
         bridge.close()
    }
}

// Push command implemented
struct PushCommand: Command {
    let deviceName: String
    func run() async throws {
         let repo = try RepoManager(path: FileManager.default.currentDirectoryPath)
         print("Scanning for \(deviceName)...")
         let scanner = Scanner()
         let devices = try await scanner.scan()
         
         guard let device = devices.first(where: { $0.name == deviceName || $0.peripheral.identifier.uuidString == deviceName }) else {
              print("Device not found. Make sure 'bltgit serve' is running on \(deviceName).")
              return
         }
         
         print("Connecting to \(device.name)...")
         let client = L2CAPClient()
         let bridge = try await client.connect(to: device)
         
         let paired = try await PairingManager.shared.performPairing(bridge: bridge, deviceName: device.name, identifier: device.peripheral.identifier, isServer: false)
         
         if paired {
              let gitClient = GitClient(bridge: bridge, repo: repo)
              try await gitClient.push()
         } else {
              print("Pairing failed.")
         }
         
         bridge.close()
    }
}

struct CloneCommand: Command {
    let deviceName: String
    let directory: String
    
    func run() async throws {
         let repo = try RepoManager.initialize(at: directory)
         print("Scanning for \(deviceName)...")
         let scanner = Scanner()
         let devices = try await scanner.scan()
         
         guard let device = devices.first(where: { $0.name == deviceName || $0.peripheral.identifier.uuidString == deviceName }) else {
              print("Device not found. Make sure 'bltgit serve' is running on \(deviceName).")
              return
         }
         
         print("Connecting to \(device.name)...")
         let client = L2CAPClient()
         let bridge = try await client.connect(to: device)
         
         let paired = try await PairingManager.shared.performPairing(bridge: bridge, deviceName: device.name, identifier: device.peripheral.identifier, isServer: false)
         
         if paired {
              let gitClient = GitClient(bridge: bridge, repo: repo)
              try await gitClient.pull()
         } else {
              print("Pairing failed.")
         }
         
         bridge.close()
    }
}

struct DevicesCommand: Command {
    func run() async throws {
         let devices = TrustStore.shared.listDevices()
         if devices.isEmpty {
              print("No trusted devices.")
         } else {
              print("Trusted devices:")
              for device in devices {
                   print("- \(device.name) (\(device.identifier)) paired \(device.pairingDate)")
              }
         }
    }
}
