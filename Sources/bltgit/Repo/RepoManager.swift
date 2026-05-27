import Foundation

class RepoManager {
    let repoURL: URL
    
    init(path: String) throws {
        self.repoURL = URL(fileURLWithPath: path)
    }
    
    static func initialize(at path: String) throws -> RepoManager {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        try process.run()
        process.waitUntilExit()
        return try RepoManager(path: path)
    }
    
    func allRefs() throws -> [String: String] {
        var refs: [String: String] = [:]
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["show-ref"]
        process.currentDirectoryURL = repoURL
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let string = String(data: data, encoding: .utf8) {
                let lines = string.components(separatedBy: .newlines).filter { !$0.isEmpty }
                for line in lines {
                    let parts = line.components(separatedBy: " ")
                    if parts.count == 2 {
                        refs[parts[1]] = parts[0]
                    }
                }
            }
        } catch {}
        
        return refs
    }
    
    func recentCommits() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-list", "--max-count=32", "HEAD"]
        process.currentDirectoryURL = repoURL
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let string = String(data: data, encoding: .utf8) {
                return string.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }
        } catch {}
        return []
    }
    
    func generatePack(wants: [String], haves: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["pack-objects", "--stdout", "--revs", "--thin", "--delta-base-offset", "-q"]
        process.currentDirectoryURL = repoURL
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        
        var inputString = ""
        for want in wants { inputString += "\(want)\n" }
        for have in haves { inputString += "^\(have)\n" }
        
        try process.run()
        inPipe.fileHandleForWriting.write(inputString.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
             throw NSError(domain: "bltgit", code: 23, userInfo: [NSLocalizedDescriptionKey: "git pack-objects failed"])
        }
        
        return data
    }
    
    func applyPack(data: Data) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["index-pack", "--stdin", "--fix-thin", "-q"]
        process.currentDirectoryURL = repoURL
        
        let inPipe = Pipe()
        process.standardInput = inPipe
        
        try process.run()
        inPipe.fileHandleForWriting.write(data)
        inPipe.fileHandleForWriting.closeFile()
        
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw NSError(domain: "bltgit", code: 24, userInfo: [NSLocalizedDescriptionKey: "git index-pack failed"])
        }
    }
    
    func updateRef(name: String, hash: String) throws {
         let process = Process()
         process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
         process.arguments = ["update-ref", name, hash]
         process.currentDirectoryURL = repoURL
         
         try process.run()
         process.waitUntilExit()
         
         if process.terminationStatus != 0 {
             throw NSError(domain: "bltgit", code: 25, userInfo: [NSLocalizedDescriptionKey: "git update-ref failed"])
         }
    }
}
