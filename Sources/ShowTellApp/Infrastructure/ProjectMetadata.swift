import Foundation
import ShowTellCore

enum ProjectMetadata {
    static func read(from directory: URL?) -> ProjectContext {
        guard let directory else { return ProjectContext() }
        return ProjectContext(
            name: directory.lastPathComponent,
            rootPath: directory.path,
            gitBranch: git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory),
            headCommit: git(["rev-parse", "HEAD"], in: directory)
        )
    }

    private static func git(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
