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
}