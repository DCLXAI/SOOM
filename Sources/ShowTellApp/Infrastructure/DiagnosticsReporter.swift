import Foundation
import Darwin

struct DiagnosticsReporter {
    func exportSupportBundle(sessions: [SessionHandle], to destination: URL) throws {
        let manager = FileManager.default
        let temporaryRoot = manager.temporaryDirectory
            .appendingPathComponent("SOOM-Support-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: temporaryRoot) }
        try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let metadata: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "hardware": ProcessInfo.processInfo.machineHardwareName,
            "sessionCount": sessions.count
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: temporaryRoot.appendingPathComponent("system.json"), options: .atomic)

        let sessionRoot = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try manager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        for handle in sessions.prefix(20) {
            let target = sessionRoot.appendingPathComponent(handle.manifest.sessionId, isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            var manifest = handle.manifest
            manifest.project.rootPath = nil
            manifest.captureLabel = manifest.captureMode
            manifest.privacy.safetyIdentifier = "redacted"
            manifest.errorMessage = nil
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: target.appendingPathComponent("session.json"), options: .atomic)

            for source in [handle.journalURL, handle.diagnosticsURL] where manager.fileExists(atPath: source.path) {
                try manager.copyItem(at: source, to: target.appendingPathComponent(source.lastPathComponent))
            }
        }

        // Raw .ips reports may contain usernames, absolute paths, loaded image
        // paths, and process arguments. Record only a count; a user can inspect
        // and attach a specific report separately when support asks for it.
        let crashSummary = ["availableCrashReportCount": recentCrashReports().prefix(10).count]
        let crashData = try JSONSerialization.data(withJSONObject: crashSummary, options: [.prettyPrinted, .sortedKeys])
        try crashData.write(to: temporaryRoot.appendingPathComponent("crashes.json"), options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", temporaryRoot.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiagnosticsError.archiveFailed }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func recentCrashReports() -> [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("SOOM-") && $0.pathExtension == "ips" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(cString: value)
    }
}

enum DiagnosticsError: LocalizedError {
    case archiveFailed

    var errorDescription: String? { "진단 패키지를 압축하지 못했습니다." }
}
