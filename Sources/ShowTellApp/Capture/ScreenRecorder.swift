import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import ShowTellCore

struct RecordingResult: Sendable {
    let durationMs: Int
    let frames: [FrameCandidate]
    let trackStartOffsets: MediaTrackStartOffsets
}

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let source: SelectedDisplaySource
    private let handle: SessionHandle
    private let camera: CameraCaptureController
    private let clock: SessionClock
    private let mediaTimeline: MediaTimeline
    private let eventLog: EventLogWriter
    private let frameCapture: FrameCaptureManager
    private let mediaWriter: CompositeMediaWriter
    private let microphoneCapture = MicrophoneCaptureController()
    private let outputSize: CGSize
    private let screenQueue = DispatchQueue(label: "com.showtellai.capture.screen", qos: .userInitiated)
    private let systemAudioQueue = DispatchQueue(label: "com.showtellai.capture.system-audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var inputMonitor: InputEventMonitor?
    private var acceptingSamples = false
    private var stopping = false
    private let onMicrophoneSample: @Sendable (CMSampleBuffer) -> Void
    private let onMicrophoneLevel: @Sendable (Double) -> Void
    private let onInputMonitoringUnavailable: @Sendable (Error) -> Void
    private let onUnexpectedStop: @Sendable (Error) -> Void
    private var lastLevelEmission = CMTime.invalid

    init(
        source: SelectedDisplaySource,
        handle: SessionHandle,
        camera: CameraCaptureController,
        clock: SessionClock,
        overlayRect: RectValue,
        quality: RecordingQuality,
        onMicrophoneSample: @escaping @Sendable (CMSampleBuffer) -> Void = { _ in },
        onMicrophoneLevel: @escaping @Sendable (Double) -> Void = { _ in },
        onInputMonitoringUnavailable: @escaping @Sendable (Error) -> Void = { _ in },
        onUnexpectedStop: @escaping @Sendable (Error) -> Void
    ) throws {
        self.source = source
        self.handle = handle
        self.camera = camera
        self.clock = clock
        let hostMediaNow = Self.hostMediaNanoseconds()
        let activeNow = clock.activeNanoseconds()
        let activeNowClamped = activeNow > UInt64(Int64.max) ? Int64.max : Int64(activeNow)
        mediaTimeline = MediaTimeline(
            captureStartHostNanoseconds: clock.startUptimeNs,
            sourceOriginNanoseconds: hostMediaNow - activeNowClamped
        )
        self.onMicrophoneSample = onMicrophoneSample
        self.onMicrophoneLevel = onMicrophoneLevel
        self.onInputMonitoringUnavailable = onInputMonitoringUnavailable
        self.onUnexpectedStop = onUnexpectedStop
        eventLog = try EventLogWriter(url: handle.eventLogURL)
        frameCapture = FrameCaptureManager(framesDirectory: handle.framesDirectory)
        let sourceSize = CGSize(
            width: source.descriptor.capturePixels.width,
            height: source.descriptor.capturePixels.height
        )
        let outputSize = quality.outputSize(for: sourceSize)
        self.outputSize = outputSize
        mediaWriter = try CompositeMediaWriter(
            screenSystemURL: handle.screenSystemURL,
            systemAudioURL: handle.systemAudioURL,
            microphoneURL: handle.microphoneURL,
            size: outputSize,
            overlayRect: overlayRect,
            quality: quality,
            compositionMode: source.mode == .cameraOnly ? .cameraOnly : .screenWithCamera
        )
        super.init()
    }

    @MainActor func start() async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.showMouseClicks = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        if let sourceRect = source.sourceRect { configuration.sourceRect = sourceRect }
        configuration.capturesAudio = source.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        // Microphone capture is intentionally handled by AVFoundation. Keeping
        // it out of SCStream avoids silent microphone buffers on some macOS 15
        // device/default-input transitions.
        configuration.captureMicrophone = false

        let stream = SCStream(filter: source.filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        if source.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
        }
        self.stream = stream

        if source.tracksInputEvents {
            let inputMonitor = InputEventMonitor(
                display: source.descriptor,
                clock: clock,
                onEvent: { [eventLog, mediaWriter] event in
                    eventLog.append(event)
                    if event.kind == .mouseDown, let point = event.position?.displayNormalizedTopLeft {
                        mediaWriter.registerClick(at: point, tMs: event.tMs)
                    }
                },
                onFrameRequest: { [frameCapture] kind, dueMs, clickPosition in
                    frameCapture.request(kind: kind, at: dueMs, clickPosition: clickPosition)
                }
            )
            do {
                try inputMonitor.start()
                self.inputMonitor = inputMonitor
            } catch {
                // Input Monitoring augments a recording but is not required to
                // produce screen, camera, microphone, or TaskSpec artifacts.
                // Keep the recording alive and make the missing capability
                // explicit without logging the system error text.
                eventLog.append(
                    InputEvent(
                        sequence: 1,
                        tMs: clock.activeMilliseconds(),
                        kind: .captureGap,
                        reason: "inputMonitoringUnavailable"
                    )
                )
                onInputMonitoringUnavailable(error)
            }
        }

        setCaptureState(acceptingSamples: true)
        do {
            try await stream.startCapture()
            try await microphoneCapture.start { [weak self] sampleBuffer in
                self?.consumeMicrophone(sampleBuffer)
            }
        } catch {
            await microphoneCapture.stop()
            try? await stream.stopCapture()
            self.inputMonitor?.stop()
            self.inputMonitor = nil
            mediaWriter.cancel()
            eventLog.close()
            throw error
        }
    }

    func setOverlayRect(_ rect: RectValue) {
        mediaWriter.setOverlayRect(rect)
    }

    func healthSnapshot(availableDiskBytes: Int64, thermalState: String) -> RecordingHealthSnapshot {
        eventLog.checkpoint()
        let durationMs = clock.activeMilliseconds()
        let writer = mediaWriter.snapshot()
        var warnings: [RecordingWarningCode] = []
        // A negative value means the OS could not report capacity. Do not turn
        // an unavailable metric into an emergency stop.
        if availableDiskBytes >= 0, availableDiskBytes < RecordingStoragePolicy.criticalAvailableBytes {
            warnings.append(.criticalDiskSpace)
        } else if availableDiskBytes >= 0, availableDiskBytes < RecordingStoragePolicy.warningAvailableBytes {
            warnings.append(.lowDiskSpace)
        }
        if thermalState == "serious" || thermalState == "critical" { warnings.append(.thermalPressure) }
        if writer.droppedVideoFrames > max(30, writer.videoFrames / 20) { warnings.append(.writerBackpressure) }
        if durationMs > 2_500, (writer.lastVideoMs ?? 0) < durationMs - 2_000 { warnings.append(.screenFramesMissing) }
        if durationMs > 2_500, (writer.lastMicrophoneMs ?? 0) < durationMs - 2_000 { warnings.append(.microphoneFramesMissing) }
        let syncOffsetMs = writer.lastVideoMs.flatMap { video in writer.lastMicrophoneMs.map { video - $0 } }
        if durationMs > 2_500, let syncOffsetMs, abs(syncOffsetMs) > 100 { warnings.append(.avSyncDrift) }
        return RecordingHealthSnapshot(
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            durationMs: durationMs,
            availableDiskBytes: availableDiskBytes,
            thermalState: thermalState,
            videoFrames: writer.videoFrames,
            systemAudioSamples: writer.systemAudioSamples,
            microphoneSamples: writer.microphoneSamples,
            droppedVideoFrames: writer.droppedVideoFrames,
            droppedSystemAudioSamples: writer.droppedSystemAudioSamples,
            droppedMicrophoneSamples: writer.droppedMicrophoneSamples,
            lastVideoMs: writer.lastVideoMs,
            lastSystemAudioMs: writer.lastSystemAudioMs,
            lastMicrophoneMs: writer.lastMicrophoneMs,
            screenMicrophoneSyncOffsetMs: syncOffsetMs,
            screenWriterStatus: writer.screenWriterStatus,
            microphoneWriterStatus: writer.microphoneWriterStatus,
            warnings: warnings
        )
    }

    @MainActor func pause() {
        let now = DispatchTime.now().uptimeNanoseconds
        clock.pause(at: now)
        mediaTimeline.pause(atHostNanoseconds: now)
        inputMonitor?.setPaused(true)
    }

    @MainActor func resume() {
        let now = DispatchTime.now().uptimeNanoseconds
        clock.resume(at: now)
        mediaTimeline.resume(atHostNanoseconds: now)
        inputMonitor?.setPaused(false)
    }

    @MainActor func stop() async throws -> RecordingResult {
        let stopRequestHostNanoseconds = DispatchTime.now().uptimeNanoseconds
        setCaptureState(acceptingSamples: false, stopping: true)
        _ = clock.freeze(at: stopRequestHostNanoseconds)
        let durationMs = mediaTimeline.freeze(atHostNanoseconds: stopRequestHostNanoseconds)

        await microphoneCapture.stop()
        do { try await stream?.stopCapture() }
        catch {
            // A stream that already stopped because of a display/device event can
            // still have valid buffered media. Continue and close the writers.
        }
        stream = nil
        let monitor = inputMonitor
        inputMonitor = nil
        monitor?.stop()
        eventLog.close()
        try await mediaWriter.finish()
        let frames = await frameCapture.finish(at: durationMs)
        let trackStartOffsets = mediaTimeline.trackStartOffsets()
        try await RecordingFinalizer.merge(
            screenSystemURL: handle.screenSystemURL,
            systemAudioURL: handle.systemAudioURL,
            microphoneURL: handle.microphoneURL,
            outputURL: handle.recordingURL,
            durationMs: durationMs,
            trackStartOffsets: trackStartOffsets
        )
        return RecordingResult(
            durationMs: durationMs,
            frames: frames,
            trackStartOffsets: trackStartOffsets
        )
    }

    @MainActor func cancel() async {
        setCaptureState(acceptingSamples: false, stopping: true)
        await microphoneCapture.stop()
        try? await stream?.stopCapture()
        stream = nil
        let monitor = inputMonitor
        inputMonitor = nil
        monitor?.stop()
        eventLog.close()
        mediaWriter.cancel()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        let shouldAccept = shouldAcceptSamples() && !clock.isPaused
        guard shouldAccept, sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            guard let screenBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let stamp = mappedTimestamp(for: sampleBuffer, track: .video) else { return }
            let time = Self.presentationTime(for: stamp)
            // Evidence intentionally consumes the clean ScreenCaptureKit frame.
            // The camera bubble and animated click pulse exist only in the
            // human-facing recording produced by CompositeMediaWriter.
            if source.mode != .cameraOnly {
                frameCapture.consume(screenBuffer, at: stamp.presentationMilliseconds)
            }
            mediaWriter.appendVideo(
                screenBuffer: screenBuffer,
                cameraBuffer: camera.latestPixelBuffer(),
                at: time
            )
        case .audio:
            guard let stamp = mappedTimestamp(for: sampleBuffer, track: .systemAudio) else { return }
            mediaWriter.appendSystemAudio(sampleBuffer, at: Self.presentationTime(for: stamp))
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private func consumeMicrophone(_ sampleBuffer: CMSampleBuffer) {
        let shouldAccept = shouldAcceptSamples() && !clock.isPaused
        guard shouldAccept, sampleBuffer.isValid else { return }
        onMicrophoneSample(sampleBuffer)
        guard let stamp = mappedTimestamp(for: sampleBuffer, track: .microphone) else { return }
        let time = Self.presentationTime(for: stamp)
        if !lastLevelEmission.isValid || time.seconds - lastLevelEmission.seconds >= 0.08 {
            lastLevelEmission = time
            onMicrophoneLevel(MicrophoneLevelMeter.level(from: sampleBuffer))
        }
        mediaWriter.appendMicrophone(sampleBuffer, at: time)
    }

    private func mappedTimestamp(
        for sampleBuffer: CMSampleBuffer,
        track: MediaTimelineTrack
    ) -> MediaTimelineStamp? {
        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourceTime.isValid, sourceTime.isNumeric else { return nil }
        let nanoseconds = CMTimeConvertScale(
            sourceTime,
            timescale: 1_000_000_000,
            method: .default
        )
        guard nanoseconds.isValid else { return nil }
        return mediaTimeline.map(
            track: track,
            sourceTimestampNanoseconds: nanoseconds.value
        )
    }

    private static func presentationTime(for stamp: MediaTimelineStamp) -> CMTime {
        CMTime(value: stamp.presentationNanoseconds, timescale: 1_000_000_000)
    }

    private static func hostMediaNanoseconds() -> Int64 {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        return CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let expected = markStoppedAndReturnWhetherExpected()
        if !expected { onUnexpectedStop(error) }
    }

    private func setCaptureState(acceptingSamples: Bool? = nil, stopping: Bool? = nil) {
        stateLock.lock(); defer { stateLock.unlock() }
        if let acceptingSamples { self.acceptingSamples = acceptingSamples }
        if let stopping { self.stopping = stopping }
    }

    private func shouldAcceptSamples() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return acceptingSamples
    }

    private func markStoppedAndReturnWhetherExpected() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        acceptingSamples = false
        return stopping
    }
}

enum MicrophoneLevelMeter {
    static func level(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr,
        let pointer,
        totalLength > 0 else { return 0 }

        let meanSquare: Double
        if description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
           description.mBitsPerChannel == 32 {
            let count = totalLength / MemoryLayout<Float>.size
            let samples = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let value = Double(samples[index])
                sum += value * value
            }
            meanSquare = count > 0 ? sum / Double(count) : 0
        } else if description.mBitsPerChannel == 16 {
            let count = totalLength / MemoryLayout<Int16>.size
            let samples = UnsafeRawPointer(pointer).bindMemory(to: Int16.self, capacity: count)
            var sum = 0.0
            for index in 0..<count {
                let value = Double(samples[index]) / Double(Int16.max)
                sum += value * value
            }
            meanSquare = count > 0 ? sum / Double(count) : 0
        } else {
            return 0
        }

        let rms = sqrt(meanSquare)
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 54) / 54, 0), 1)
    }
}
