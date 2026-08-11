import Testing
import Foundation
@testable import bltgit

// MARK: - Helpers

struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Tests

@Suite("RepoManager Tests")
struct bltgitTests {

    @Test("Initializing a repo creates the folder and .git directory")
    func repoInitialization() throws {
        let temp = try TempDirectory()
        defer { try? temp.cleanup() }

        let repoPath = temp.url.appendingPathComponent("testRepo").path
        let repo = try RepoManager.initialize(at: repoPath)

        #expect(FileManager.default.fileExists(atPath: repoPath),
                "Repository folder should be created")

        let gitFolder = repo.repoURL.appendingPathComponent(".git").path
        #expect(FileManager.default.fileExists(atPath: gitFolder),
                ".git folder should be created and initialized")
    }

    @Test("A freshly initialized repo has no refs")
    func repoRefsEmptyInitially() throws {
        let temp = try TempDirectory()
        defer { try? temp.cleanup() }

        let repoPath = temp.url.appendingPathComponent("testRepoEmpty").path
        let repo = try RepoManager.initialize(at: repoPath)

        let refs = try repo.allRefs()
        #expect(refs.isEmpty, "A newly initialized repo should have no refs")
    }

    @Test("Command parser recognizes ping command")
    func pingCommandParsing() {
        let command = CommandParser.parse(arguments: ["bltgit", "ping", "MyMac"])
        #expect(command is PingCommand, "Expected 'ping' to parse as PingCommand")
    }

    @Test("Ping command requires a device argument")
    func pingCommandRequiresDevice() {
        let command = CommandParser.parse(arguments: ["bltgit", "ping"])
        #expect(command == nil, "Expected nil when ping is missing device argument")
    }

    @Test("Device matching is case-insensitive and supports UUIDs")
    func deviceMatchingIgnoresCase() {
        let identifier = "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D"

        #expect(matchesDeviceIdentity(name: "MyMac", identifier: identifier, query: "mymac"))
        #expect(matchesDeviceIdentity(name: "MyMac", identifier: identifier, query: identifier.lowercased()))
        #expect(!matchesDeviceIdentity(name: "MyMac", identifier: identifier, query: "other"))
    }
}