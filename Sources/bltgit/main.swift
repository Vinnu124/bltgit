import Foundation

let arguments = CommandLine.arguments

if let command = CommandParser.parse(arguments: arguments) {
    Task {
         do {
              try await command.run()
              if !(command is ServeCommand) {
                   exit(0)
              }
         } catch {
              print("Failed: \(error)")
              exit(1)
         }
    }
    
    RunLoop.main.run()
} else {
    CommandParser.printHelp()
    exit(1)
}
