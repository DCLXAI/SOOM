import AVFoundation
import CoreVideo
import Foundation

final class CameraCaptureController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published private(set) var isRunning = false
    @Published private(set) var cameraName = "Camera"

    private let sessionQueue = DispatchQueue(label: "com.showtellai.camera.session")
    private let outputQueue = DispatchQueue(label: "com.showtellai.camera.output")
    private let frameLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var configured = false

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async { self.isRunning = true }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.frameLock.lock()
            self.latestBuffer = nil
            self.frameLock.unlock()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func reconnect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                self.session.stopRunning()
                self.session.beginConfiguration()
                for input in self.session.inputs { self.session.removeInput(input) }
                for output in self.session.outputs { self.session.removeOutput(output) }
                self.session.commitConfiguration()
                self.configured = false
                self.frameLock.lock()
                self.latestBuffer = nil
                self.frameLock.unlock()
                do {
                    try self.configureIfNeeded()
                    self.session.startRunning()
                    DispatchQueue.main.async { self.isRunning = true }
                    continuation.resume()
                } catch {
                    DispatchQueue.main.async { self.isRunning = false }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func latestPixelBuffer() -> CVPixelBuffer? {
        frameLock.lock(); defer { frameLock.unlock() }
        return latestBuffer
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        latestBuffer = buffer
        frameLock.unlock()
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraError.inputRejected }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw CameraError.outputRejected }
        session.addOutput(output)

        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        configured = true
        DispatchQueue.main.async { self.cameraName = camera.localizedName }
    }
}

enum CameraError: LocalizedError {
    case unavailable
    case inputRejected
    case outputRejected

    var errorDescription: String? {
        switch self {
        case .unavailable: return "사용 가능한 webcam을 찾을 수 없습니다."
        case .inputRejected: return "webcam 입력을 시작할 수 없습니다."
        case .outputRejected: return "webcam 프레임 출력을 시작할 수 없습니다."
        }
    }
}
