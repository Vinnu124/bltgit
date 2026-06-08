import Foundation
import CoreBluetooth

@MainActor
protocol Command {
    func run() async throws
}

// MARK: - serve

struct ServeCommand: Command {
    func run() async throws {
        let repo = try RepoManager(path: FileManager.default.currentDirectoryPath)
        print("Serving repo at \(repo.repoURL.path)...")
        
        let advertiser = Advertiser()
        advertiser.onChannelOpened = { channel in
            print("New connection from \(channel.peer.identifier)")
            Task {
                let bridge = L2CAPServer().handle(channel: channel)
                // Guarantee close() is called even when an error propagates.
                defer { bridge.close() }
                do {
                    let paired = try await PairingManager.shared.performPairing(
                        bridge: bridge,
                        deviceName: "Unknown",
                        identifier: channel.peer.identifier,
                        isServer: true
                    )
                    if paired {
                        let gitServer = GitServer(bridge: bridge, repo: repo)
                        try await gitServer.pull()
                    } else {
                        print("Pairing failed or rejected.")
                    }
                } catch {
                    print("Connection error from \(channel.peer.identifier): \(error)")
                }
            }
        }
        
        advertiser.onError = { error in
            print("Bluetooth error: \(error)")
        }
        
        advertiser.startAdvertising()

        // Keep the server alive indefinitely.
        try? await Task.sleep(nanoseconds: UInt64.max)
    }
}

// MARK: - discover

struct DiscoverCommand: Command {
    func run() async throws {
        print("Scanning for nearby bltgit devices...")
        let scanner = Scanner()
        let devices = try await scanner.scan()
        if devices.isEmpty {
            print("No bltgit devices found nearby.")
        } else {
            for device in devices {
                print("Found: \(device.name) (\(device.peripheral.identifier))  RSSI: \(device.rssi) dBm")
            }
        }
    }
}

// MARK: - pull

struct PullCommand: Command {
    let deviceName: String

    func run() async throws {
        let repo = try RepoManager(path: FileManager.default.currentDirectoryPath)
        print("Scanning for \(deviceName)...")
        let devices = try await Scanner().scan()

        guard let device = devices.first(where: {
            $0.name == deviceName || $0.peripheral.identifier.uuidString == deviceName
        }) else {
            print("Device not found. Make sure 'bltgit serve' is running on \(deviceName).")
            return
        }

        print("Connecting to \(device.name)...")
        let bridge = try await L2CAPClient().connect(to: device)
        defer { bridge.close() }

        let paired = try await PairingManager.shared.performPairing(
            bridge: bridge,
            deviceName: device.name,
            identifier: device.peripheral.identifier,
            isServer: false
        )

        if paired {
            try await GitClient(bridge: bridge, repo: repo).pull()
        } else {
            print("Pairing failed.")
        }
    }
}

// MARK: - push

struct PushCommand: Command {
    let deviceName: String

    func run() async throws {
        let repo = try RepoManager(path: FileManager.default.currentDirectoryPath)
        print("Scanning for \(deviceName)...")
        let devices = try await Scanner().scan()

        guard let device = devices.first(where: {
            $0.name == deviceName || $0.peripheral.identifier.uuidString == deviceName
        }) else {
            print("Device not found. Make sure 'bltgit serve' is running on \(deviceName).")
            return
        }

        print("Connecting to \(device.name)...")
        let bridge = try await L2CAPClient().connect(to: device)
        defer { bridge.close() }

        let paired = try await PairingManager.shared.performPairing(
            bridge: bridge,
            deviceName: device.name,
            identifier: device.peripheral.identifier,
            isServer: false
        )

        if paired {
            try await GitClient(bridge: bridge, repo: repo).push()
        } else {
            print("Pairing failed.")
        }
    }
}

// MARK: - clone

struct CloneCommand: Command {
    let deviceName: String
    let directory: String
    
    func run() async throws {
        let repo = try RepoManager.initialize(at: directory)
        print("Scanning for \(deviceName)...")
        let devices = try await Scanner().scan()

        guard let device = devices.first(where: {
            $0.name == deviceName || $0.peripheral.identifier.uuidString == deviceName
        }) else {
            print("Device not found. Make sure 'bltgit serve' is running on \(deviceName).")
            return
        }

        print("Connecting to \(device.name)...")
        let bridge = try await L2CAPClient().connect(to: device)
        defer { bridge.close() }

        let paired = try await PairingManager.shared.performPairing(
            bridge: bridge,
            deviceName: device.name,
            identifier: device.peripheral.identifier,
            isServer: false
        )

        if paired {
            try await GitClient(bridge: bridge, repo: repo).pull()
        } else {
            print("Pairing failed.")
        }
    }
}

// MARK: - devices

struct DevicesCommand: Command {
    func run() async throws {
        let devices = TrustStore.shared.listDevices()
        if devices.isEmpty {
            print("No trusted devices.")
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            print("Trusted devices:")
            for device in devices {
                print("  • \(device.name) (\(device.identifier)) — paired \(formatter.string(from: device.pairingDate))")
            }
        }
    }
}
