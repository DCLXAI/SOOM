import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ShowTellCore

final class CompositeMediaWriter: @unchecked Sendable {
    enum CompositionMode {
        case screenWithCamera
        case cameraOnly
    }

    private struct ClickPulse {
        let point: PointValue
        let tMs: Int
    }

    struct Snapshot: Sendable {
        let videoFrames: Int
        let systemAudioSamples: Int
        let microphoneSamples: Int
        let droppedVideoFrames: Int
        let droppedSystemAudioSamples: Int
        let droppedMicrophoneSamples: Int
        let lastVideoMs: Int?
        let lastSystemAudioMs: Int?
        let lastMicrophoneMs: Int?
        let screenWriterStatus: String
        let microphoneWriterStatus: String
    }

    private let screenWriter: AVAssetWriter
    private let systemAudioWriter: AVAssetWriter
    private let microphoneWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput
    private let microphoneInput: AVAssetWriterInput
    private let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let intermediateURLs: [URL]
    private let expectsSystemAudio: Bool
    private let queue = DispatchQueue(label: "com.showtellai.media-writer")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let canvasSize: CGSize
    private let compositionMode: CompositionMode
    private var overlayRect: RectValue
    private var clickPulse: ClickPulse?
    private var videoFrames = 0
    private var systemAudioSamples = 0
    private var microphoneSamples = 0
    private var droppedVideoFrames = 0
    private var droppedSystemAudioSamples = 0
    private var droppedMicrophoneSamples = 0
    private var lastVideoMs: Int?
    private var lastSystemAudioMs: Int?
    private var lastMicrophoneMs: Int?

    init(
        screenSystemURL: URL,
        systemAudioURL: URL,
        microphoneURL: URL,
        size: CGSize,
        overlayRect: RectValue,
        quality: RecordingQuality,
        compositionMode: CompositionMode = .screenWithCamera
    ) throws {
        try? FileManager.default.removeItem(at: screenSystemURL)
        try? FileManager.default.removeItem(at: systemAudioURL)
        try? FileManager.default.removeItem(at: microphoneURL)
        canvasSize = size
        self.overlayRect = overlayRect
        self.compositionMode = compositionMode
        intermediateURLs = [screenSystemURL, systemAudioURL, microphoneURL]
        expectsSystemAudio = compositionMode != .cameraOnly

        screenWriter = try AVAssetWriter(outputURL: screenSystemURL, fileType: .mp4)
        systemAudioWriter = try AVAssetWriter(outputURL: systemAudioURL, fileType: .m4a)
        microphoneWriter = try AVAssetWriter(outputURL: microphoneURL, fileType: .m4a)
        let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        screenWriter.movieFragmentInterval = fragmentInterval
        systemAudioWriter.movieFragmentInterval = fragmentInterval
        microphoneWriter.movieFragmentInterval = fragmentInterval
        screenWriter.shouldOptimizeForNetworkUse = true
        systemAudioWriter.shouldOptimizeForNetworkUse = true
        microphoneWriter.shouldOptimizeForNetworkUse = true

        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: quality.averageVideoBitRate,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoAllowFrameReorderingKey: false
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = true

        systemAudioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
        )
        systemAudioInput.expectsMediaDataInRealTime = true

        microphoneInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        microphoneInput.expectsMediaDataInRealTime = true

        guard screenWriter.canAdd(videoInput),
              systemAudioWriter.canAdd(systemAudioInput),
              microphoneWriter.canAdd(microphoneInput) else {
            throw MediaWriterError.cannotAddInput
        }
        screenWriter.add(videoInput)
        systemAudioWriter.add(systemAudioInput)
        microphoneWriter.add(microphoneInput)

        pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard screenWriter.startWriting(), systemAudioWriter.startWriting(), microphoneWriter.startWriting() else {
            throw MediaWriterError.cannotStart(
                screenWriter.error ?? systemAudioWriter.error ?? microphoneWriter.error
            )
        }
        screenWriter.startSession(atSourceTime: .zero)
        systemAudioWriter.startSession(atSourceTime: .zero)
        microphoneWriter.startSession(atSourceTime: .zero)
        do {
            try secureIntermediateFiles()
        } catch {
            screenWriter.cancelWriting()
            systemAudioWriter.cancelWriting()
            microphoneWriter.cancelWriting()
            throw MediaWriterError.cannotSecureIntermediateFiles(error)
        }
    }

    func setOverlayRect(_ rect: RectValue) {
        queue.async { self.overlayRect = rect }
    }

    func registerClick(at point: PointValue, tMs: Int) {
        queue.async { self.clickPulse = ClickPulse(point: point, tMs: tMs) }
    }

    func appendVideo(
        screenBuffer: CVPixelBuffer,
        cameraBuffer: CVPixelBuffer?,
        at presentationTime: CMTime
    ) {
        queue.async {
            let tMs = Self.milliseconds(presentationTime)
            guard self.videoInput.isReadyForMoreMediaData,
                  let pool = self.pixelAdaptor.pixelBufferPool else {
                self.droppedVideoFrames += 1
                return
            }
            var output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
                  let output else {
                self.droppedVideoFrames += 1
                return
            }

            let rendered = self.composite(
                screen: screenBuffer,
                camera: cameraBuffer,
                tMs: Int((presentationTime.seconds * 1_000).rounded())
            )
            self.ciContext.render(
                rendered,
                to: output,
                bounds: CGRect(origin: .zero, size: self.canvasSize),
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
            guard self.pixelAdaptor.append(output, withPresentationTime: presentationTime) else {
                self.droppedVideoFrames += 1
                return
            }
            self.videoFrames += 1
            self.lastVideoMs = tMs
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer, at presentationTime: CMTime) {
        queue.async {
            guard self.systemAudioInput.isReadyForMoreMediaData,
                  let adjusted = sampleBuffer.retimed(to: presentationTime),
                  self.systemAudioInput.append(adjusted) else {
                self.droppedSystemAudioSamples += 1
                return
            }
            self.systemAudioSamples += 1
            self.lastSystemAudioMs = Self.milliseconds(presentationTime)
        }
    }

    func appendMicrophone(_ sampleBuffer: CMSampleBuffer, at presentationTime: CMTime) {
        queue.async {
            guard self.microphoneInput.isReadyForMoreMediaData,
                  let adjusted = sampleBuffer.retimed(to: presentationTime),
                  self.microphoneInput.append(adjusted) else {
                self.droppedMicrophoneSamples += 1
                return
            }
            self.microphoneSamples += 1
            self.lastMicrophoneMs = Self.milliseconds(presentationTime)
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                videoFrames: videoFrames,
                systemAudioSamples: systemAudioSamples,
                microphoneSamples: microphoneSamples,
                droppedVideoFrames: droppedVideoFrames,
                droppedSystemAudioSamples: droppedSystemAudioSamples,
                droppedMicrophoneSamples: droppedMicrophoneSamples,
                lastVideoMs: lastVideoMs,
                lastSystemAudioMs: lastSystemAudioMs,
                lastMicrophoneMs: lastMicrophoneMs,
                screenWriterStatus: Self.statusName(screenWriter.status),
                microphoneWriterStatus: Self.statusName(microphoneWriter.status)
            )
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.videoInput.markAsFinished()
                self.systemAudioInput.markAsFinished()
                self.microphoneInput.markAsFinished()

                let group = DispatchGroup()
                group.enter()
                self.screenWriter.finishWriting { group.leave() }
                group.enter()
                self.systemAudioWriter.finishWriting { group.leave() }
                group.enter()
                self.microphoneWriter.finishWriting { group.leave() }
                group.notify(queue: self.queue) {
                    if self.screenWriter.status == .failed {
                        continuation.resume(throwing: MediaWriterError.finishFailed(
                            component: "화면 영상",
                            error: self.screenWriter.error
                        ))
                    } else if self.systemAudioWriter.status == .failed,
                              self.expectsSystemAudio || self.systemAudioSamples > 0 {
                        continuation.resume(throwing: MediaWriterError.finishFailed(
                            component: "시스템 오디오",
                            error: self.systemAudioWriter.error
                        ))
                    } else if self.microphoneWriter.status == .failed {
                        continuation.resume(throwing: MediaWriterError.finishFailed(
                            component: "마이크",
                            error: self.microphoneWriter.error
                        ))
                    } else {
                        do {
                            try self.secureIntermediateFiles()
                            continuation.resume(returning: ())
                        } catch {
                            continuation.resume(throwing: MediaWriterError.cannotSecureIntermediateFiles(error))
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        queue.sync {
            screenWriter.cancelWriting()
            systemAudioWriter.cancelWriting()
            microphoneWriter.cancelWriting()
        }
    }

    private func composite(screen: CVPixelBuffer, camera: CVPixelBuffer?, tMs: Int) -> CIImage {
        let target = CGRect(origin: .zero, size: canvasSize)
        if compositionMode == .cameraOnly {
            guard let camera else {
                return CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.08)).cropped(to: target)
            }
            return aspectFill(CIImage(cvPixelBuffer: camera), into: target)
        }
        let source = CIImage(cvPixelBuffer: screen)
        let screenScale = max(target.width / source.extent.width, target.height / source.extent.height)
        var background = source.transformed(by: CGAffineTransform(scaleX: screenScale, y: screenScale))
        background = background.cropped(to: target)
        background = applyingClickPulse(to: background, at: tMs)

        guard let camera else { return background }
        let normalized = overlayRect
        let cameraRect = CGRect(
            x: normalized.x * target.width,
            y: (1 - normalized.y - normalized.height) * target.height,
            width: normalized.width * target.width,
            height: normalized.height * target.height
        )
        guard cameraRect.width > 4, cameraRect.height > 4 else { return background }

        var face = CIImage(cvPixelBuffer: camera)
        let scale = max(cameraRect.width / face.extent.width, cameraRect.height / face.extent.height)
        face = face.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropX = face.extent.midX - cameraRect.width / 2
        let cropY = face.extent.midY - cameraRect.height / 2
        face = face.cropped(to: CGRect(x: cropX, y: cropY, width: cameraRect.width, height: cameraRect.height))
        face = face.transformed(by: CGAffineTransform(translationX: cameraRect.minX - cropX, y: cameraRect.minY - cropY))

        let radius = min(cameraRect.width, cameraRect.height) / 2
        guard let mask = CIFilter(
            name: "CIRadialGradient",
            parameters: [
                kCIInputCenterKey: CIVector(x: cameraRect.midX, y: cameraRect.midY),
                "inputRadius0": max(0, radius - 2),
                "inputRadius1": radius,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear
            ]
        )?.outputImage?.cropped(to: cameraRect),
        let result = CIFilter(
            name: "CIBlendWithMask",
            parameters: [
                kCIInputImageKey: face,
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask
            ]
        )?.outputImage else { return background }
        return result.cropped(to: target)
    }

    private func aspectFill(_ image: CIImage, into target: CGRect) -> CIImage {
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translation = CGAffineTransform(
            translationX: target.midX - scaled.extent.midX,
            y: target.midY - scaled.extent.midY
        )
        return scaled.transformed(by: translation).cropped(to: target)
    }

    private func applyingClickPulse(to background: CIImage, at tMs: Int) -> CIImage {
        guard let clickPulse else { return background }
        let age = tMs - clickPulse.tMs
        guard age >= 0, age <= 700 else {
            if age > 700 { self.clickPulse = nil }
            return background
        }
        let progress = CGFloat(age) / 700
        let radius = 18 + progress * 58
        let alpha = (1 - progress) * 0.42
        let center = CIVector(
            x: clickPulse.point.x * canvasSize.width,
            y: (1 - clickPulse.point.y) * canvasSize.height
        )
        guard let pulse = CIFilter(
            name: "CIRadialGradient",
            parameters: [
                kCIInputCenterKey: center,
                "inputRadius0": 0,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 0.2, blue: 0.12, alpha: alpha * 0.35),
                "inputColor1": CIColor(red: 1, green: 0.2, blue: 0.12, alpha: 0)
            ]
        )?.outputImage else { return background }
        let bounds = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        return pulse.cropped(to: bounds).composited(over: background).cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    private static func milliseconds(_ time: CMTime) -> Int? {
        guard time.isValid, time.seconds.isFinite else { return nil }
        return Int((time.seconds * 1_000).rounded())
    }

    private static func statusName(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .writing: return "writing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    private func secureIntermediateFiles() throws {
        for url in intermediateURLs {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }
}

private extension CMSampleBuffer {
    func retimed(to presentationTime: CMTime) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return self }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        let originalStart = timing[0].presentationTimeStamp
        for index in timing.indices {
            let relative = timing[index].presentationTimeStamp - originalStart
            timing[index].presentationTimeStamp = presentationTime + relative
            timing[index].decodeTimeStamp = .invalid
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}

enum MediaWriterError: LocalizedError {
    case cannotAddInput
    case cannotStart(Error?)
    case cannotSecureIntermediateFiles(Error)
    case finishFailed(component: String, error: Error?)

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: return "녹화 미디어 트랙을 만들 수 없습니다."
        case let .cannotStart(error): return error?.localizedDescription ?? "녹화를 시작할 수 없습니다."
        case let .cannotSecureIntermediateFiles(error):
            return "녹화 중간 파일 권한을 보호할 수 없습니다: \(error.localizedDescription)"
        case let .finishFailed(component, error):
            let detail = Self.diagnosticDescription(error)
            return "\(component) 저장에 실패했습니다\(detail.isEmpty ? "." : ": \(detail)")"
        }
    }

    private static func diagnosticDescription(_ error: Error?) -> String {
        guard let error else { return "" }
        let nsError = error as NSError
        var parts = ["\(nsError.domain) \(nsError.code)", nsError.localizedDescription]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain) \(underlying.code)")
            parts.append(underlying.localizedDescription)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
