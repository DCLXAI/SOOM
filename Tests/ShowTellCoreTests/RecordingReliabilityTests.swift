import Foundation
import ShowTellCore
import Testing

@Suite("Recording reliability contracts")
struct RecordingReliabilityTests {
    @Test func storagePreflightAllowsUnknownCapacityButBlocksCriticalCapacity() {
        #expect(RecordingStoragePolicy.canStartRecording(availableBytes: nil))
        #expect(!RecordingStoragePolicy.canStartRecording(availableBytes: 275_000_000))
        #expect(RecordingStoragePolicy.canStartRecording(
            availableBytes: RecordingStoragePolicy.criticalAvailableBytes
        ))
    }

    @Test func fourKStoragePreflightAccountsForSourceAndFinalizedCopies() {
        let required1080 = RecordingStoragePolicy.requiredAvailableBytes(
            quality: .standard1080p,
            maximumDurationMs: 180_000
        )
        let required4K = RecordingStoragePolicy.requiredAvailableBytes(
            quality: .ultra4K,
            maximumDurationMs: 180_000
        )

        #expect(required1080 >= RecordingStoragePolicy.criticalAvailableBytes)
        #expect(required4K > required1080)
        #expect(!RecordingStoragePolicy.canStartRecording(
            availableBytes: required4K - 1,
            quality: .ultra4K,
            maximumDurationMs: 180_000
        ))
        #expect(RecordingStoragePolicy.canStartRecording(
            availableBytes: required4K,
            quality: .ultra4K,
            maximumDurationMs: 180_000
        ))
    }

    @Test("journal checkpoints round-trip without losing recovery state")
    func journalRoundTrip() throws {
        var journal = RecordingJournal(
            sessionId: "session-1",
            quality: .standard1080p,
            startedAt: "2026-08-13T12:00:00Z"
        )
        journal.checkpointSequence = 7
        journal.recoveryAttempts = 1
        journal.health = health(warnings: [.writerBackpressure])

        let data = try JSONEncoder().encode(journal)
        let decoded = try JSONDecoder().decode(RecordingJournal.self, from: data)

        #expect(decoded == journal)
        #expect(decoded.cleanShutdown == false)
        #expect(decoded.health?.warnings == [.writerBackpressure])
    }

    @Test("quality profiles remain stable persisted values")
    func qualityPersistence() throws {
        let values = RecordingQuality.allCases
        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([RecordingQuality].self, from: data) == values)
        #expect(RecordingQuality.standard1080p.title.contains("30fps"))
        #expect(RecordingQuality.ultra4K.rawValue == "ultra4K")
    }

    @Test("health snapshot preserves the measured sync offset")
    func syncOffsetContract() throws {
        let snapshot = health(warnings: [.avSyncDrift])
        let decoded = try JSONDecoder().decode(
            RecordingHealthSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.screenMicrophoneSyncOffsetMs == 125)
        #expect(decoded.warnings.contains(.avSyncDrift))
    }

    private func health(warnings: [RecordingWarningCode]) -> RecordingHealthSnapshot {
        RecordingHealthSnapshot(
            capturedAt: "2026-08-13T12:00:01Z",
            durationMs: 1_000,
            availableDiskBytes: 20_000_000_000,
            thermalState: "nominal",
            videoFrames: 30,
            systemAudioSamples: 50,
            microphoneSamples: 50,
            droppedVideoFrames: 0,
            droppedSystemAudioSamples: 0,
            droppedMicrophoneSamples: 0,
            lastVideoMs: 1_000,
            lastSystemAudioMs: 980,
            lastMicrophoneMs: 875,
            screenMicrophoneSyncOffsetMs: 125,
            screenWriterStatus: "writing",
            microphoneWriterStatus: "writing",
            warnings: warnings
        )
    }
}
