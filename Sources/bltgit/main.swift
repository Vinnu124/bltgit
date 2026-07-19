import Foundation

// CommandParser.parse() must run on the main actor because Command
// conforming types are @MainActor-isolated (their init() is implicit @MainActor).
Task { @MainActor in
    let arguments = CommandLine.arguments

    guard let command = CommandParser.parse(arguments: arguments) else {
        CommandParser.printHelp()
        exit(1)
    }

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
