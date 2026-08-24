import AVFoundation
import CoreMedia
import Foundation

final class MicrophoneCaptureController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.showtellai.microphone.session")
    private let outputQueue = DispatchQueue(label: "com.showtellai.microphone.output", qos: .userInitiated)
    private let callbackLock = NSLock()
    private var output: AVCaptureAudioDataOutput?
    private var onSample: (@Sendable (CMSampleBuffer) -> Void)?

    func start(onSample: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    self.callbackLock.lock()
                    self.onSample = onSample
                    self.callbackLock.unlock()

                    self.session.beginConfiguration()
                    do {
                        for input in self.session.inputs { self.session.removeInput(input) }
                        for output in self.session.outputs { self.session.removeOutput(output) }

                        guard let device = AVCaptureDevice.default(for: .audio) else {
                            throw MicrophoneCaptureError.unavailable
                        }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else {
                            throw MicrophoneCaptureError.inputRejected
                        }
                        self.session.addInput(input)

                        let output = AVCaptureAudioDataOutput()
                        output.setSampleBufferDelegate(self, queue: self.outputQueue)
                        guard self.session.canAddOutput(output) else {
                            throw MicrophoneCaptureError.outputRejected
                        }
                        self.session.addOutput(output)
                        self.output = output
                        self.session.commitConfiguration()
                    } catch {
                        self.session.commitConfiguration()
                        throw error
                    }
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    if self.session.isRunning { self.session.stopRunning() }
                    self.callbackLock.lock()
                    self.onSample = nil
                    self.callbackLock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.output?.setSampleBufferDelegate(nil, queue: nil)
                self.output = nil
                self.callbackLock.lock()
                self.onSample = nil
                self.callbackLock.unlock()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        callbackLock.lock()
        let callback = onSample
        callbackLock.unlock()
        callback?(sampleBuffer)
    }
}

private enum MicrophoneCaptureError: LocalizedError {
    case unavailable
    case inputRejected
    case outputRejected

    var errorDescription: String? {
        switch self {
        case .unavailable: return "사용 가능한 마이크를 찾을 수 없습니다."
        case .inputRejected: return "기본 마이크 입력을 열 수 없습니다."
        case .outputRejected: return "마이크 오디오 출력을 시작할 수 없습니다."
        }
    }
}
