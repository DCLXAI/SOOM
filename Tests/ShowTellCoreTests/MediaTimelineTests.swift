import Testing
@testable import ShowTellCore

@Suite("Capture-wide media timeline")
struct MediaTimelineTests {
    private let second: Int64 = 1_000_000_000

    @Test("sample PTS preserves relative first-track offsets")
    func preservesFirstTrackOffsets() {
        let timeline = MediaTimeline(
            captureStartHostNanoseconds: 1_000,
            sourceOriginNanoseconds: 10 * second
        )

        let video = timeline.map(track: .video, sourceTimestampNanoseconds: 10 * second + 50_000_000)
        let system = timeline.map(track: .systemAudio, sourceTimestampNanoseconds: 10 * second + 82_000_000)
        let microphone = timeline.map(track: .microphone, sourceTimestampNanoseconds: 10 * second + 125_000_000)

        #expect(video?.presentationMilliseconds == 50)
        #expect(system?.presentationMilliseconds == 82)
        #expect(microphone?.presentationMilliseconds == 125)
        #expect(
            timeline.trackStartOffsets()
                == MediaTrackStartOffsets(videoMs: 50, systemAudioMs: 82, microphoneMs: 125)
        )
    }

    @Test("explicit pause duration is compacted from every track")
    func compactsPause() {
        let timeline = MediaTimeline(
            captureStartHostNanoseconds: 0,
            sourceOriginNanoseconds: 20 * second
        )
        _ = timeline.map(track: .video, sourceTimestampNanoseconds: 20 * second + 100_000_000)
        _ = timeline.map(track: .microphone, sourceTimestampNanoseconds: 20 * second + 110_000_000)

        timeline.pause(atHostNanoseconds: 200_000_000)
        timeline.resume(atHostNanoseconds: 1_200_000_000)

        let video = timeline.map(track: .video, sourceTimestampNanoseconds: 21 * second + 133_000_000)
        let microphone = timeline.map(track: .microphone, sourceTimestampNanoseconds: 21 * second + 143_000_000)

        #expect(video?.presentationMilliseconds == 133)
        #expect(microphone?.presentationMilliseconds == 143)
        #expect(video?.didCompactDiscontinuity == false)
        #expect(microphone?.didCompactDiscontinuity == false)
    }

    @Test("forward and backward PTS discontinuities remain monotonic")
    func compactsUnexpectedDiscontinuities() {
        let timeline = MediaTimeline(
            captureStartHostNanoseconds: 0,
            sourceOriginNanoseconds: 30 * second
        )
        let first = timeline.map(track: .video, sourceTimestampNanoseconds: 30 * second)
        let secondFrame = timeline.map(track: .video, sourceTimestampNanoseconds: 30 * second + 33_000_000)
        let forwardJump = timeline.map(track: .video, sourceTimestampNanoseconds: 35 * second)
        let backwardJump = timeline.map(track: .video, sourceTimestampNanoseconds: 29 * second)

        #expect(first?.presentationMilliseconds == 0)
        #expect(secondFrame?.presentationMilliseconds == 33)
        #expect(forwardJump?.presentationMilliseconds == 66)
        #expect(forwardJump?.didCompactDiscontinuity == true)
        #expect(backwardJump?.presentationMilliseconds == 99)
        #expect(backwardJump?.didCompactDiscontinuity == true)
    }

    @Test("stop freezes active duration and rejects late samples")
    func freezesAtStopRequest() {
        let timeline = MediaTimeline(
            captureStartHostNanoseconds: 1 * UInt64(second),
            sourceOriginNanoseconds: 40 * second
        )
        _ = timeline.map(track: .video, sourceTimestampNanoseconds: 40 * second + 100_000_000)
        timeline.pause(atHostNanoseconds: 1_500_000_000)
        timeline.resume(atHostNanoseconds: 3_000_000_000)

        #expect(timeline.freeze(atHostNanoseconds: 3_500_000_000) == 1_000)
        #expect(timeline.freeze(atHostNanoseconds: 9_000_000_000) == 1_000)
        #expect(timeline.map(track: .video, sourceTimestampNanoseconds: 45 * second) == nil)
    }

    @Test("stopping while paused freezes at the pause boundary")
    func freezesAtPauseBoundary() {
        let timeline = MediaTimeline(
            captureStartHostNanoseconds: 1_000_000_000,
            sourceOriginNanoseconds: 50 * second
        )
        timeline.pause(atHostNanoseconds: 1_750_000_000)

        #expect(timeline.freeze(atHostNanoseconds: 8_000_000_000) == 750)
    }
}
