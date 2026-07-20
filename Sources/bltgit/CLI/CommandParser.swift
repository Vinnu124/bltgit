import Foundation

class CommandParser {
    static func parse(arguments: [String]) -> Command? {
        guard arguments.count > 1 else { return nil }
        
        let commandStr = arguments[1]
        
        switch commandStr {
        case "serve":
            return ServeCommand()
        case "discover":
            return DiscoverCommand()
        case "pull":
            if arguments.count == 3 {
                return PullCommand(deviceName: arguments[2])
            }
        case "fetch":
            if arguments.count == 3 {
                return FetchCommand(deviceName: arguments[2])
            }
        case "push":
             if arguments.count == 3 {
                 return PushCommand(deviceName: arguments[2])
             }
        case "clone":
             if arguments.count == 4 {
                 return CloneCommand(deviceName: arguments[2], directory: arguments[3])
             }
        case "log":
            if arguments.count >= 3 {
                // bltgit log <device> [--count N]
                var count = 20
                if let flagIdx = arguments.firstIndex(of: "--count"),
                   flagIdx + 1 < arguments.count,
                   let n = Int(arguments[flagIdx + 1]), n > 0 {
                    count = n
                }
                return LogCommand(deviceName: arguments[2], count: count)
            }
        case "status":
            if arguments.count == 3 {
                return StatusCommand(deviceName: arguments[2])
            }
        case "devices":
             return DevicesCommand()
        case "unpair":
            if arguments.count == 3 {
                return UnpairCommand(deviceName: arguments[2])
            }
        default:
             return nil
        }
        
        return nil
    }
    
    static func printHelp() {
        print("""
bltgit - Git Over Bluetooth

Usage:
  bltgit serve                  Serve the current directory over Bluetooth
  bltgit discover               Discover nearby bltgit devices
  bltgit pull <device>          Pull commits from <device> (fetch + checkout)
  bltgit fetch <device>         Fetch commits into refs/remotes/bltgit/ without checkout
  bltgit push <device>          Push commits to <device>
  bltgit clone <device> <dir>   Clone repo from <device> into <dir>
  bltgit log <device>           Show recent commits on <device> without pulling
  bltgit log <device> --count N Show the last N commits (default: 20)
  bltgit status <device>        Compare local branches with <device> (no data transferred)
  bltgit devices                List trusted devices
  bltgit unpair <device>         Remove a trusted device (next connect will re-prompt PIN)
""")
    }
}
