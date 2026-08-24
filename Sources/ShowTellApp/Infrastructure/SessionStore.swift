import AppKit
import Foundation
import ShowTellCore

struct SessionHandle: Sendable {
    let directory: URL
    var manifest: SessionManifest

    var manifestURL: URL { directory.appendingPathComponent("session.json") }
    var eventLogURL: URL { directory.appendingPathComponent("events.ndjson") }
    var framesDirectory: URL { directory.appendingPathComponent("frames", isDirectory: true) }
    var frameIndexURL: URL { framesDirectory.appendingPathComponent("index.json") }
    var journalURL: URL { directory.appendingPathComponent("journal.json") }
    var diagnosticsURL: URL { directory.appendingPathComponent("diagnostics.ndjson") }
    var screenSystemURL: URL { directory.appendingPathComponent("screen-system.mp4") }
    var systemAudioURL: URL { directory.appendingPathComponent("system-audio.m4a") }
    var microphoneURL: URL { directory.appendingPathComponent("microphone.m4a") }
    var recordingURL: URL { directory.appendingPathComponent("recording.mp4") }
}

enum SessionStoreError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Application Support 폴더를 열 수 없습니다."
        }
    }
}

final class SessionStore {
    static let shared = SessionStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private init() {}

    func create(
        display: DisplayDescriptor,
        overlay: RectValue,
        project: ProjectContext,
        safetyIdentifier: String,
        hostStartUptimeNs: UInt64,
        captureMode: CaptureMode,
        captureLabel: String,
        quality: RecordingQuality,
        diagnosticsConsent: Bool
    ) throws -> SessionHandle {
        let id = UUID().uuidString.lowercased()
        let base = try sessionsDirectory()
        let directory = base.appendingPathComponent(id, isDirectory: true)
        let frames = directory.appendingPathComponent("frames", isDirectory: true)

        try fileManager.createDirectory(at: frames, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileManager.createFile(atPath: directory.appendingPathComponent("events.ndjson").path, contents: nil, attributes: [.posixPermissions: 0o600])
        fileManager.createFile(atPath: directory.appendingPathComponent("diagnostics.ndjson").path, contents: nil, attributes: [.posixPermissions: 0o600])

        let manifest = SessionManifest(
            sessionId: id,
            state: .preparing,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            hostStartUptimeNs: hostStartUptimeNs,
            captureMode: captureMode.rawValue,
            captureLabel: captureLabel,
            display: display,
            cameraOverlayNormalizedTopLeft: overlay,
            project: project,
            privacy: PrivacyPolicy(safetyIdentifier: safetyIdentifier)
        )
        var configuredManifest = manifest
        configuredManifest.recordingQuality = quality.rawValue
        configuredManifest.diagnosticsConsent = diagnosticsConsent
        let handle = SessionHandle(directory: directory, manifest: configuredManifest)
        try writeManifest(handle.manifest, to: handle.manifestURL)
        try writeJournal(
            RecordingJournal(sessionId: id, quality: quality, startedAt: manifest.createdAt),
            to: handle.journalURL
        )
        return handle
    }

    func update(_ handle: inout SessionHandle, mutate: (inout SessionManifest) -> Void) throws {
        mutate(&handle.manifest)
        try writeManifest(handle.manifest, to: handle.manifestURL)
    }

    func writeFrames(_ frames: [FrameCandidate], to handle: SessionHandle) throws {
        let data = try encoder.encode(frames)
        try atomicWrite(data, to: handle.frameIndexURL)
    }

    func checkpoint(_ snapshot: RecordingHealthSnapshot, for handle: SessionHandle) throws {
        var journal = (try? loadJournal(for: handle))
            ?? RecordingJournal(
                sessionId: handle.manifest.sessionId,
                quality: RecordingQuality(rawValue: handle.manifest.recordingQuality ?? "") ?? .standard1080p,
                startedAt: handle.manifest.createdAt
            )
        journal.checkpointSequence += 1
        journal.lastHeartbeatAt = snapshot.capturedAt
        journal.health = snapshot
        try writeJournal(journal, to: handle.journalURL)
    }

    func markCleanShutdown(_ handle: SessionHandle) throws {
        guard var journal = try? loadJournal(for: handle) else { return }
        journal.cleanShutdown = true
        journal.lastHeartbeatAt = ISO8601DateFormatter().string(from: Date())
        try writeJournal(journal, to: handle.journalURL)
    }

    func markRecoveryAttempt(_ handle: SessionHandle) throws {
        guard var journal = try? loadJournal(for: handle) else { return }
        journal.recoveryAttempts += 1
        try writeJournal(journal, to: handle.journalURL)
    }

    func markRecovered(_ handle: SessionHandle) throws {
        guard var journal = try? loadJournal(for: handle) else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        journal.cleanShutdown = true
        journal.recoveredAt = timestamp
        journal.lastHeartbeatAt = timestamp
        try writeJournal(journal, to: handle.journalURL)
    }

    func loadJournal(for handle: SessionHandle) throws -> RecordingJournal {
        try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: handle.journalURL))
    }

    func appendDiagnostic(_ record: [String: String], to handle: SessionHandle) {
        guard handle.manifest.diagnosticsConsent == true,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let file = try? FileHandle(forWritingTo: handle.diagnosticsURL) else { return }
        defer { try? file.close() }
        do {
            try file.seekToEnd()
            try file.write(contentsOf: data)
            try file.write(contentsOf: Data([0x0A]))
            try file.synchronize()
        } catch { return }
    }

    func allSessions() throws -> [SessionHandle] {
        let decoder = JSONDecoder()
        let candidates = try recoverableSessionDirectories().flatMap { directory in
            try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        }
        return candidates.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
                  let manifest = try? decoder.decode(SessionManifest.self, from: data) else { return nil }
            return SessionHandle(directory: directory, manifest: manifest)
        }
        .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Removes sensitive keyboard content from sessions created by older SOOM
    /// builds before those sessions can be reopened, exported, or processed.
    @discardableResult
    func migrateLegacyEventPrivacy() throws -> Int {
        var migratedSessionCount = 0
        for original in try allSessions() {
            guard original.manifest.privacy.recordsRawKeystrokesLocally ||
                    !original.manifest.privacy.recordsTypingActivityLocally ||
                    !original.manifest.privacy.recordsSafeShortcutsLocally else { continue }

            var handle = original
            let source = (try? Data(contentsOf: handle.eventLogURL)) ?? Data()
            let result = EventLogPrivacyMigration.migrate(source)
            try atomicWrite(result.data, to: handle.eventLogURL)
            try update(&handle) { manifest in
                manifest.privacy.recordsRawKeystrokesLocally = false
                manifest.privacy.recordsTypingActivityLocally = true
                manifest.privacy.recordsSafeShortcutsLocally = true
            }
            appendDiagnostic(
                [
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "stage": "privacy-migration",
                    "status": "success",
                    "migratedEvents": String(result.migratedEvents),
                    "droppedMalformedLines": String(result.droppedMalformedLines)
                ],
                to: handle
            )
            migratedSessionCount += 1
        }
        return migratedSessionCount
    }

    func interruptedSessions() throws -> [SessionHandle] {
        try allSessions().filter { handle in
            guard [.preparing, .recording, .finalizing, .interrupted, .recovering].contains(handle.manifest.state) else {
                return false
            }
            return (try? loadJournal(for: handle).cleanShutdown) != true
        }
    }

    func loadTaskSpec(from handle: SessionHandle) throws -> TaskSpec {
        let url = handle.directory.appendingPathComponent("taskspec.json")
        return try JSONDecoder().decode(TaskSpec.self, from: Data(contentsOf: url))
    }

    func latestRecoverableSession() throws -> SessionHandle? {
        let directories = try recoverableSessionDirectories()
        let candidates = try directories.flatMap { directory in
            try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        }
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }

        let decoder = JSONDecoder()
        for candidate in candidates {
            let manifestURL = candidate.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(SessionManifest.self, from: data),
                  manifest.state == .failed || manifest.state == .processing else { continue }
            return SessionHandle(directory: candidate, manifest: manifest)
        }
        return nil
    }

    func reveal(_ handle: SessionHandle) {
        NSWorkspace.shared.activateFileViewerSelecting([handle.directory])
    }

    func recycle(_ handle: SessionHandle) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([handle.directory]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func recordingStorageDirectory() throws -> URL {
        try sessionsDirectory()
    }

    private func sessionsDirectory() throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SessionStoreError.applicationSupportUnavailable
        }
        let directory = support.appendingPathComponent("SOOM/Sessions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func recoverableSessionDirectories() throws -> [URL] {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SessionStoreError.applicationSupportUnavailable
        }
        let current = try sessionsDirectory()
        let legacy = support.appendingPathComponent("ShowTellAI/Sessions", isDirectory: true)
        if fileManager.fileExists(atPath: legacy.path) { return [current, legacy] }
        return [current]
    }

    private func writeManifest(_ manifest: SessionManifest, to url: URL) throws {
        try atomicWrite(encoder.encode(manifest), to: url)
    }

    private func writeJournal(_ journal: RecordingJournal, to url: URL) throws {
        try atomicWrite(encoder.encode(journal), to: url)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class EventLogWriter {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.showtellai.event-log")
    private let encoder = JSONEncoder()

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ event: InputEvent) {
        queue.async { [encoder, handle] in
            guard let data = try? encoder.encode(event) else { return }
            handle.write(data)
            handle.write(Data([0x0A]))
        }
    }

    func checkpoint() {
        queue.sync { try? handle.synchronize() }
    }

    func close() {
        queue.sync {
            try? handle.synchronize()
            try? handle.close()
        }
    }
}
