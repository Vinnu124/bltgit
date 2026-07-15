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
            if arguments.count == 3 {
                return LogCommand(deviceName: arguments[2])
            }
        case "devices":
             return DevicesCommand()
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
  bltgit devices                List trusted devices
""")
    }
}
