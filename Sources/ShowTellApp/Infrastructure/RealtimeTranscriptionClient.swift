import AVFoundation
import CoreMedia
import Foundation
import ShowTellCore

enum RealtimeTranscriptionState: Equatable, Sendable {
    case disabled
    case connecting
    case listening
    case unavailable(String)

    var overlayLabel: String {
        switch self {
        case .disabled: return "실시간 자막 꺼짐"
        case .connecting: return "AI 자막 연결 중…"
        case .listening: return "AI 실시간 자막"
        case .unavailable: return "AI 자막 연결 끊김 · 녹화 계속 중"
        }
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// A best-effort side channel. Failure is deliberately reported through state
/// callbacks and never bubbles into the canonical local recording pipeline.
final class RealtimeTranscriptionClient: @unchecked Sendable {
    typealias StateHandler = @Sendable (RealtimeTranscriptionState) -> Void
    typealias CaptionHandler = @Sendable (String) -> Void

    private let apiKey: String
    private let safetyIdentifier: String
    private let onState: StateHandler
    private let onCaption: CaptionHandler
    private let encoder = RealtimePCMEncoder()
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var outgoing: AsyncStream<String>.Continuation?
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var accumulator = RealtimeTranscriptAccumulator()
    private var stopped = false

    init(
        apiKey: String,
        safetyIdentifier: String,
        onState: @escaping StateHandler,
        onCaption: @escaping CaptionHandler
    ) {
        self.apiKey = apiKey
        self.safetyIdentifier = safetyIdentifier
        self.onState = onState
        self.onCaption = onCaption
    }

    func start() {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe") else {
            onState(.unavailable("Realtime URL을 만들 수 없습니다."))
            return
        }

        onState(.connecting)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")

        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        let (stream, continuation) = AsyncStream<String>.makeStream()

        lock.lock()
        self.session = session
        self.socket = socket
        outgoing = continuation
        stopped = false
        lock.unlock()

        sendTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            for await payload in stream {
                do {
                    try await socket.send(.string(payload))
                } catch {
                    self.reportUnavailable(error)
                    return
                }
            }
        }
        receiveTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    switch message {
                    case let .string(text): self.handle(text)
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    @unknown default: break
                    }
                }
            } catch {
                self.reportUnavailable(error)
            }
        }

        socket.resume()
        enqueue(Self.sessionConfiguration)
    }

    /// Encodes synchronously while ScreenCaptureKit still owns the sample
    /// buffer, then queues only detached Data for network delivery.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = encoder.encode(sampleBuffer), !pcm.isEmpty else { return }
        enqueue([
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString()
        ])
    }

    func finish() async {
        enqueue(["type": "input_audio_buffer.commit"])
        try? await Task.sleep(for: .milliseconds(650))
        close()
    }

    func cancel() {
        close()
    }

    private func close() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let socket = self.socket
        let session = self.session
        let continuation = outgoing
        self.socket = nil
        self.session = nil
        outgoing = nil
        lock.unlock()

        continuation?.finish()
        receiveTask?.cancel()
        sendTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func enqueue(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        enqueue(text)
    }

    private func enqueue(_ text: String) {
        lock.lock()
        let continuation = stopped ? nil : outgoing
        lock.unlock()
        continuation?.yield(text)
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "session.updated", "input_audio_buffer.speech_started":
            onState(.listening)
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = event["item_id"] as? String,
                  let delta = event["delta"] as? String else { return }
            lock.lock()
            accumulator.append(delta: delta, itemID: itemID)
            let caption = accumulator.visibleCaption
            lock.unlock()
            onCaption(caption)
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = event["item_id"] as? String,
                  let transcript = event["transcript"] as? String else { return }
            lock.lock()
            accumulator.complete(transcript: transcript, itemID: itemID)
            let caption = accumulator.visibleCaption
            lock.unlock()
            onCaption(caption)
        case "error":
            let details = event["error"] as? [String: Any]
            let message = details?["message"] as? String ?? "Realtime API 오류"
            reportUnavailable(message)
        default:
            break
        }
    }

    private func reportUnavailable(_ error: Error) {
        reportUnavailable(error.localizedDescription)
    }

    private func reportUnavailable(_ message: String) {
        lock.lock()
        let shouldReport = !stopped
        lock.unlock()
        if shouldReport { onState(.unavailable(message)) }
    }

    private static let sessionConfiguration: [String: Any] = [
        "type": "session.update",
        "session": [
            "type": "transcription",
            "audio": [
                "input": [
                    "format": [
                        "type": "audio/pcm",
                        "rate": 24_000
                    ],
                    "transcription": [
                        "model": "gpt-live-transcribe",
                        "prompt": "웹 UI 수정사항을 한국어 또는 영어로 설명하는 SOOM 녹화입니다. Codex, Claude Code, Figma, hero, CTA, navigation, responsive 같은 제품·개발 용어를 정확히 받아쓰세요.",
                        "languages": ["ko", "en"],
                        "delay": "low"
                    ],
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 550
                    ]
                ]
            ]
        ]
    ]
}

private final class RealtimePCMEncoder: @unchecked Sendable {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterInputSignature: InputSignature?

    func encode(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = streamDescription.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return nil }
        input.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: input.mutableAudioBufferList
        ) == noErr else { return nil }

        let signature = InputSignature(inputFormat)
        if converter == nil || converterInputSignature != signature {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputSignature = signature
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var suppliedInput = false
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    private struct InputSignature: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat
        let interleaved: Bool

        init(_ format: AVAudioFormat) {
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            commonFormat = format.commonFormat
            interleaved = format.isInterleaved
        }
    }
}
