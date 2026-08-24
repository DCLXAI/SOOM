import AVFoundation
import Foundation
import ShowTellCore

enum RecordingFinalizer {
    static func merge(
        screenSystemURL: URL,
        systemAudioURL: URL? = nil,
        microphoneURL: URL? = nil,
        outputURL: URL,
        durationMs: Int? = nil,
        trackStartOffsets: MediaTrackStartOffsets = .init()
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let screenAsset = AVURLAsset(url: screenSystemURL)
        let microphoneAsset = microphoneURL.map(AVURLAsset.init(url:))
        let assetDuration = try await screenAsset.load(.duration)
        let requestedDuration = durationMs.map {
            CMTime(value: CMTimeValue(max(0, $0)), timescale: 1_000)
        }
        let duration = requestedDuration ?? assetDuration
        let composition = AVMutableComposition()

        guard let sourceVideo = try await screenAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw RecordingFinalizerError.videoMissing
        }
        let sourceVideoRange = try await sourceVideo.load(.timeRange)
        guard let videoPlacement = placement(
            sourceRange: sourceVideoRange,
            startOffsetMs: resolvedStartOffsetMs(
                explicit: trackStartOffsets.videoMs,
                sourceRange: sourceVideoRange
            ),
            targetDuration: duration
        ) else {
            throw RecordingFinalizerError.videoMissing
        }
        try videoTrack.insertTimeRange(videoPlacement.sourceRange, of: sourceVideo, at: videoPlacement.destinationStart)

        var mixParameters: [AVAudioMixInputParameters] = []
        var retainedSystemAudioAsset: AVURLAsset?
        var sourceSystemAudio: AVAssetTrack?
        if let systemAudioURL,
           FileManager.default.fileExists(atPath: systemAudioURL.path) {
            let systemAudioAsset = AVURLAsset(url: systemAudioURL)
            retainedSystemAudioAsset = systemAudioAsset
            sourceSystemAudio = try? await systemAudioAsset.loadTracks(withMediaType: .audio).first
        }
        if sourceSystemAudio == nil {
            sourceSystemAudio = try? await screenAsset.loadTracks(withMediaType: .audio).first
        }
        if let sourceSystemAudio,
           let systemTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let sourceRange = try await sourceSystemAudio.load(.timeRange)
            if let audioPlacement = placement(
                sourceRange: sourceRange,
                startOffsetMs: resolvedStartOffsetMs(
                    explicit: trackStartOffsets.systemAudioMs,
                    sourceRange: sourceRange
                ),
                targetDuration: duration
            ) {
                try systemTrack.insertTimeRange(
                    audioPlacement.sourceRange,
                    of: sourceSystemAudio,
                    at: audioPlacement.destinationStart
                )
                let parameters = AVMutableAudioMixInputParameters(track: systemTrack)
                parameters.setVolume(0.72, at: audioPlacement.destinationStart)
                mixParameters.append(parameters)
            }
        }
        if let microphoneAsset,
           let sourceMicrophone = try await microphoneAsset.loadTracks(withMediaType: .audio).first,
           let microphoneTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let sourceRange = try await sourceMicrophone.load(.timeRange)
            if let audioPlacement = placement(
                sourceRange: sourceRange,
                startOffsetMs: resolvedStartOffsetMs(
                    explicit: trackStartOffsets.microphoneMs,
                    sourceRange: sourceRange
                ),
                targetDuration: duration
            ) {
                try microphoneTrack.insertTimeRange(
                    audioPlacement.sourceRange,
                    of: sourceMicrophone,
                    at: audioPlacement.destinationStart
                )
                let parameters = AVMutableAudioMixInputParameters(track: microphoneTrack)
                parameters.setVolume(1, at: audioPlacement.destinationStart)
                mixParameters.append(parameters)
            }
        }

        if composition.duration < duration {
            composition.insertEmptyTimeRange(
                CMTimeRange(start: composition.duration, duration: duration - composition.duration)
            )
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingFinalizerError.exporterUnavailable
        }
        exporter.audioMix = audioMix
        try await exporter.export(to: outputURL, as: .mp4)
        _ = retainedSystemAudioAsset
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    }

    private struct TrackPlacement {
        let sourceRange: CMTimeRange
        let destinationStart: CMTime
    }

    private static func placement(
        sourceRange: CMTimeRange,
        startOffsetMs: Int,
        targetDuration: CMTime
    ) -> TrackPlacement? {
        let rawOffset = CMTime(value: CMTimeValue(startOffsetMs), timescale: 1_000)
        let destinationStart = startOffsetMs >= 0 ? rawOffset : .zero
        let leadingTrim = startOffsetMs < 0
            ? CMTime(value: CMTimeValue(-startOffsetMs), timescale: 1_000)
            : .zero
        let sourceStart = sourceRange.start + leadingTrim
        let availableSourceDuration = sourceRange.end - sourceStart
        let availableTargetDuration = targetDuration - destinationStart
        let insertDuration = CMTimeMinimum(availableSourceDuration, availableTargetDuration)
        guard insertDuration.isNumeric, insertDuration > .zero else { return nil }
        return TrackPlacement(
            sourceRange: CMTimeRange(start: sourceStart, duration: insertDuration),
            destinationStart: destinationStart
        )
    }

    private static func resolvedStartOffsetMs(
        explicit: Int?,
        sourceRange: CMTimeRange
    ) -> Int {
        if let explicit { return explicit }
        guard sourceRange.start.isNumeric, sourceRange.start.seconds.isFinite else { return 0 }
        return Int((sourceRange.start.seconds * 1_000).rounded())
    }
}

enum RecordingFinalizerError: LocalizedError {
    case videoMissing
    case exporterUnavailable

    var errorDescription: String? {
        switch self {
        case .videoMissing: return "화면 녹화 비디오 트랙을 찾을 수 없습니다."
        case .exporterUnavailable: return "화면과 마이크를 하나의 녹화 파일로 합칠 수 없습니다."
        }
    }
}
