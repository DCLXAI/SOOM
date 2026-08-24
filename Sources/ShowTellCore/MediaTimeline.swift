import Foundation

public enum MediaTimelineTrack: String, Codable, CaseIterable, Sendable {
    case video
    case systemAudio
    case microphone
}

public struct MediaTrackStartOffsets: Codable, Equatable, Sendable {
    public var videoMs: Int?
    public var systemAudioMs: Int?
    public var microphoneMs: Int?

    public init(videoMs: Int? = nil, systemAudioMs: Int? = nil, microphoneMs: Int? = nil) {
        self.videoMs = videoMs
        self.systemAudioMs = systemAudioMs
        self.microphoneMs = microphoneMs
    }
}

public struct MediaTimelineStamp: Equatable, Sendable {
    public var presentationNanoseconds: Int64
    public var didCompactDiscontinuity: Bool

    public var presentationMilliseconds: Int {
        Int(presentationNanoseconds / 1_000_000)
    }
}

/// Maps capture-source timestamps onto one session-wide media timeline.
///
/// Sample PTS remains the source of truth. A single host-clock calibration made
/// when capture starts aligns that PTS domain with the session clock; callback
/// scheduling latency is therefore not baked into individual media timestamps.
/// Explicit pauses are removed, and unexpected source-clock jumps are compacted
/// per track so AVAssetWriter always receives strictly increasing timestamps.
public final class MediaTimeline: @unchecked Sendable {
    private struct TrackState {
        var firstPresentationNanoseconds: Int64
        var lastSourceNanoseconds: Int64
        var lastPresentationNanoseconds: Int64
        var sourceCorrectionNanoseconds: Int64
        var expectedStepNanoseconds: Int64?
    }

    private let captureStartHostNanoseconds: UInt64
    private let sourceOriginNanoseconds: Int64
    private let discontinuityThresholdNanoseconds: Int64
    private let lock = NSLock()
    private var trackStates: [MediaTimelineTrack: TrackState] = [:]
    private var pausedAtHostNanoseconds: UInt64?
    private var totalPausedNanoseconds: UInt64 = 0
    private var frozenDurationNanoseconds: UInt64?

    public init(
        captureStartHostNanoseconds: UInt64,
        sourceOriginNanoseconds: Int64,
        discontinuityThresholdNanoseconds: Int64 = 2_000_000_000
    ) {
        self.captureStartHostNanoseconds = captureStartHostNanoseconds
        self.sourceOriginNanoseconds = sourceOriginNanoseconds
        self.discontinuityThresholdNanoseconds = max(1, discontinuityThresholdNanoseconds)
    }

    public func map(
        track: MediaTimelineTrack,
        sourceTimestampNanoseconds: Int64
    ) -> MediaTimelineStamp? {
        lock.lock(); defer { lock.unlock() }
        guard frozenDurationNanoseconds == nil else { return nil }

        let paused = clampedInt64(totalPausedNanoseconds)
        let uncorrected = subtractingWithoutOverflow(
            subtractingWithoutOverflow(sourceTimestampNanoseconds, sourceOriginNanoseconds),
            paused
        )

        guard var state = trackStates[track] else {
            // A buffered sample can precede the calibrated session origin by a
            // tiny amount. Trim that pre-roll instead of emitting a negative PTS.
            let presentation = max(0, uncorrected)
            trackStates[track] = TrackState(
                firstPresentationNanoseconds: presentation,
                lastSourceNanoseconds: sourceTimestampNanoseconds,
                lastPresentationNanoseconds: presentation,
                sourceCorrectionNanoseconds: presentation - uncorrected,
                expectedStepNanoseconds: nil
            )
            return MediaTimelineStamp(
                presentationNanoseconds: presentation,
                didCompactDiscontinuity: presentation != uncorrected
            )
        }

        var presentation = addingWithoutOverflow(uncorrected, state.sourceCorrectionNanoseconds)
        let sourceDelta = subtractingWithoutOverflow(sourceTimestampNanoseconds, state.lastSourceNanoseconds)
        var didCompact = false

        let fallbackStep = max(1, min(state.expectedStepNanoseconds ?? 1_000_000, 100_000_000))
        let presentationDelta = subtractingWithoutOverflow(presentation, state.lastPresentationNanoseconds)
        if sourceDelta <= 0 || presentationDelta <= 0 || presentationDelta > discontinuityThresholdNanoseconds {
            let desired = addingWithoutOverflow(state.lastPresentationNanoseconds, fallbackStep)
            state.sourceCorrectionNanoseconds = addingWithoutOverflow(
                state.sourceCorrectionNanoseconds,
                subtractingWithoutOverflow(desired, presentation)
            )
            presentation = desired
            didCompact = true
        } else if presentationDelta <= discontinuityThresholdNanoseconds {
            // Presentation delta has the explicit pause duration removed while
            // source delta does not, so it is the better cadence estimate.
            state.expectedStepNanoseconds = presentationDelta
        }

        state.lastSourceNanoseconds = sourceTimestampNanoseconds
        state.lastPresentationNanoseconds = presentation
        trackStates[track] = state
        return MediaTimelineStamp(
            presentationNanoseconds: presentation,
            didCompactDiscontinuity: didCompact
        )
    }

    public func pause(atHostNanoseconds now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard frozenDurationNanoseconds == nil, pausedAtHostNanoseconds == nil else { return }
        pausedAtHostNanoseconds = now
    }

    public func resume(atHostNanoseconds now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard frozenDurationNanoseconds == nil, let pausedAtHostNanoseconds else { return }
        if now >= pausedAtHostNanoseconds {
            totalPausedNanoseconds = addingWithoutOverflow(
                totalPausedNanoseconds,
                now - pausedAtHostNanoseconds
            )
        }
        self.pausedAtHostNanoseconds = nil
    }

    /// Freezes duration at the instant stop was requested. Repeated calls are
    /// idempotent, and no subsequent media sample can extend the timeline.
    @discardableResult
    public func freeze(atHostNanoseconds now: UInt64) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let frozenDurationNanoseconds {
            return milliseconds(frozenDurationNanoseconds)
        }
        let effectiveNow = pausedAtHostNanoseconds ?? now
        let elapsed = effectiveNow >= captureStartHostNanoseconds
            ? effectiveNow - captureStartHostNanoseconds
            : 0
        let active = elapsed >= totalPausedNanoseconds
            ? elapsed - totalPausedNanoseconds
            : 0
        frozenDurationNanoseconds = active
        return milliseconds(active)
    }

    public func trackStartOffsets() -> MediaTrackStartOffsets {
        lock.lock(); defer { lock.unlock() }
        return MediaTrackStartOffsets(
            videoMs: trackStates[.video].map { Int($0.firstPresentationNanoseconds / 1_000_000) },
            systemAudioMs: trackStates[.systemAudio].map { Int($0.firstPresentationNanoseconds / 1_000_000) },
            microphoneMs: trackStates[.microphone].map { Int($0.firstPresentationNanoseconds / 1_000_000) }
        )
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Int {
        let value = nanoseconds / 1_000_000
        return value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private func clampedInt64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return value }
        return rhs >= 0 ? Int64.max : Int64.min
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private func subtractingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard overflow else { return value }
        return rhs < 0 ? Int64.max : Int64.min
    }
}
