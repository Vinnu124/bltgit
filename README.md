# bltgit

A Swift command-line tool to transfer, clone, and push Git repositories directly between Macs over Bluetooth. It uses Apple CoreBluetooth and L2CAP channels to move Git packfiles without requiring an internet connection or local Wi-Fi network.

## Features

* **Mac-to-Mac Bluetooth Transfer:** Uses CoreBluetooth L2CAP channels for high-throughput local data streaming.
* **Git Packfile Integration:** Directly reads and unpacks raw Git data, automatically handling `git init` and `git checkout`.
* **Chunked Data Delivery:** Splits large repositories into reliable 60KB byte chunks with sequence tracking and retry logic.
* **Secure Pairing:** Implements a Mutual Trust Handshake with active PIN validation to ensure secure peer-to-peer connections.
* **Thread-Safe Streams:** Uses NSLock polling loops to prevent macOS RunLoop deadlocks during heavy byte transfers.

## Available Commands

* `bltgit serve`
Starts broadcasting the current repository over Bluetooth so nearby Macs can fetch it.

* `bltgit discover`
Scans the surrounding area for other Macs currently running the serve command.

* `bltgit clone <Target_UUID_or_Name> <Local_Folder>`
Initiates a secure connection to the specified Mac and clones its repository into your local folder.

* `bltgit push` (In Development)
Pushes local commits back to the connected Mac over Bluetooth.

## Technical Requirements

* macOS 13.0 or higher.
* Swift 5.8 or higher.
* Active Bluetooth hardware.

