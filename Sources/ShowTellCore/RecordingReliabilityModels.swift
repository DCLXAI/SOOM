import Foundation

public enum RecordingQuality: String, Codable, CaseIterable, Sendable {
    case standard1080p
    case ultra4K

    public var title: String {
        switch self {
        case .standard1080p: return "1080p · 30fps"
        case .ultra4K: return "4K · 30fps"
        }
    }
}

public enum RecordingStoragePolicy {
    /// Recording creates a screen source, a microphone source, and a finalized
    /// composite. Keep enough headroom for all three files and APFS metadata.
    public static let criticalAvailableBytes: Int64 = 1_000_000_000
    public static let warningAvailableBytes: Int64 = 5_000_000_000

    public static func canStartRecording(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return true }
        return availableBytes >= criticalAvailableBytes
    }

    public static func requiredAvailableBytes(
        quality: RecordingQuality,
        maximumDurationMs: Int
    ) -> Int64 {
        let videoBitRate: Int64 = quality == .ultra4K ? 24_000_000 : 8_000_000
        let durationSeconds = Int64(max(1, maximumDurationMs / 1_000))
        let encodedVideoBytes = (videoBitRate / 8) * durationSeconds
        // SOOM temporarily owns source video, the finalized output, audio
        // tracks, fragments, and filesystem overhead. A 2.5x multiplier plus
        // fixed headroom prevents a 4K session from starting with only the old
        // one-gigabyte minimum.
        let workingSet = Int64(Double(encodedVideoBytes) * 2.5) + 300_000_000
        return max(criticalAvailableBytes, workingSet)
    }

    public static func canStartRecording(
        availableBytes: Int64?,
        quality: RecordingQuality,
        maximumDurationMs: Int
    ) -> Bool {
        guard let availableBytes else { return true }
        return availableBytes >= requiredAvailableBytes(
            quality: quality,
            maximumDurationMs: maximumDurationMs
        )
    }
}

public enum RecordingWarningCode: String, Codable, Sendable {
    case lowDiskSpace
    case criticalDiskSpace
    case thermalPressure
    case writerBackpressure
    case screenFramesMissing
    case microphoneFramesMissing
    case avSyncDrift
    case cameraDisconnected
    case microphoneDisconnected
    case displayDisconnected
    case displayConfigurationChanged
    case systemWillSleep
}

public struct RecordingHealthSnapshot: Codable, Equatable, Sendable {
    public var capturedAt: String
    public var durationMs: Int
    public var availableDiskBytes: Int64
    public var thermalState: String
    public var videoFrames: Int
    public var systemAudioSamples: Int
    public var microphoneSamples: Int
    public var droppedVideoFrames: Int
    public var droppedSystemAudioSamples: Int
    public var droppedMicrophoneSamples: Int
    public var lastVideoMs: Int?
    public var lastSystemAudioMs: Int?
    public var lastMicrophoneMs: Int?
    public var screenMicrophoneSyncOffsetMs: Int?
    public var screenWriterStatus: String
    public var microphoneWriterStatus: String
    public var warnings: [RecordingWarningCode]

    public init(
        capturedAt: String,
        durationMs: Int,
        availableDiskBytes: Int64,
        thermalState: String,
        videoFrames: Int,
        systemAudioSamples: Int,
        microphoneSamples: Int,
        droppedVideoFrames: Int,
        droppedSystemAudioSamples: Int,
        droppedMicrophoneSamples: Int,
        lastVideoMs: Int?,
        lastSystemAudioMs: Int?,
        lastMicrophoneMs: Int?,
        screenMicrophoneSyncOffsetMs: Int?,
        screenWriterStatus: String,
        microphoneWriterStatus: String,
        warnings: [RecordingWarningCode]
    ) {
        self.capturedAt = capturedAt
        self.durationMs = durationMs
        self.availableDiskBytes = availableDiskBytes
        self.thermalState = thermalState
        self.videoFrames = videoFrames
        self.systemAudioSamples = systemAudioSamples
        self.microphoneSamples = microphoneSamples
        self.droppedVideoFrames = droppedVideoFrames
        self.droppedSystemAudioSamples = droppedSystemAudioSamples
        self.droppedMicrophoneSamples = droppedMicrophoneSamples
        self.lastVideoMs = lastVideoMs
        self.lastSystemAudioMs = lastSystemAudioMs
        self.lastMicrophoneMs = lastMicrophoneMs
        self.screenMicrophoneSyncOffsetMs = screenMicrophoneSyncOffsetMs
        self.screenWriterStatus = screenWriterStatus
        self.microphoneWriterStatus = microphoneWriterStatus
        self.warnings = warnings
    }
}

public struct RecordingJournal: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var sessionId: String
    public var quality: RecordingQuality
    public var startedAt: String
    public var lastHeartbeatAt: String
    public var checkpointSequence: Int
    public var cleanShutdown: Bool
    public var recoveryAttempts: Int
    public var recoveredAt: String?
    public var health: RecordingHealthSnapshot?

    public init(sessionId: String, quality: RecordingQuality, startedAt: String) {
        schemaVersion = "1.0"
        self.sessionId = sessionId
        self.quality = quality
        self.startedAt = startedAt
        lastHeartbeatAt = startedAt
        checkpointSequence = 0
        cleanShutdown = false
        recoveryAttempts = 0
        recoveredAt = nil
        health = nil
    }
}
