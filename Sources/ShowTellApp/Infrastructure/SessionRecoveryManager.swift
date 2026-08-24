import AVFoundation
import Foundation
import ShowTellCore

struct SessionRecoveryManager {
    let store: SessionStore

    func recoverInterruptedSessions() async -> [SessionHandle] {
        guard let interrupted = try? store.interruptedSessions() else { return [] }
        var recovered: [SessionHandle] = []
        for original in interrupted {
            if let handle = await recover(original) { recovered.append(handle) }
        }
        return recovered
    }

    private func recover(_ original: SessionHandle) async -> SessionHandle? {
        var handle = original
        do {
            try store.markRecoveryAttempt(handle)
            try store.update(&handle) { manifest in
                manifest.state = .recovering
                manifest.errorMessage = nil
            }
            let screenInput = try recoverableMediaURL(
                finalizedURL: handle.screenSystemURL,
                minimumSize: 4_096
            )
            let microphoneInput = try? recoverableMediaURL(
                finalizedURL: handle.microphoneURL,
                minimumSize: 1_024
            )
            let systemAudioInput = try? recoverableMediaURL(
                finalizedURL: handle.systemAudioURL,
                minimumSize: 1_024
            )

            try await RecordingFinalizer.merge(
                screenSystemURL: screenInput,
                systemAudioURL: systemAudioInput,
                microphoneURL: microphoneInput,
                outputURL: handle.recordingURL
            )
            let asset = AVURLAsset(url: handle.recordingURL)
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            guard playable, duration.isValid, duration.seconds.isFinite, duration.seconds >= 0.25 else {
                throw SessionRecoveryError.outputNotPlayable
            }

            // Evidence and microphone enrich TaskSpec generation, but neither
            // is allowed to make an otherwise playable video unrecoverable.
            let frames = recoveredFrameCandidates(in: handle.framesDirectory)
            try store.writeFrames(frames, to: handle)
            let recoveredAt = ISO8601DateFormatter().string(from: Date())
            try store.update(&handle) { manifest in
                manifest.state = .recorded
                manifest.durationMs = Int((duration.seconds * 1_000).rounded(.down))
                manifest.artifacts.recording = CaptureArtifact(path: "recording.mp4")
                manifest.artifacts.microphone = microphoneInput == nil
                    ? nil
                    : CaptureArtifact(path: "microphone.m4a")
                manifest.recoveredAt = recoveredAt
                manifest.errorMessage = microphoneInput == nil
                    ? "비정상 종료된 영상을 복구했습니다. 마이크 파일이 없어 TaskSpec 생성은 사용할 수 없습니다."
                    : "비정상 종료된 녹화를 복구했습니다. TaskSpec 생성을 다시 시도해 주세요."
            }
            try store.markRecovered(handle)
            store.appendDiagnostic(
                ["at": recoveredAt, "stage": "session-recovery", "status": "success"],
                to: handle
            )
            return handle
        } catch {
            try? store.update(&handle) { manifest in
                manifest.state = .failed
                manifest.errorMessage = "비정상 종료 세션 복구 실패: \(error.localizedDescription)"
            }
            store.appendDiagnostic(
                [
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "stage": "session-recovery",
                    "status": "failed",
                    "errorType": String(describing: type(of: error))
                ],
                to: handle
            )
            return nil
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func recoverableMediaURL(
        finalizedURL: URL,
        minimumSize: Int64
    ) throws -> URL {
        if fileSize(finalizedURL) >= minimumSize { return finalizedURL }

        let directory = finalizedURL.deletingLastPathComponent()
        let prefix = finalizedURL.lastPathComponent + ".sb-"
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { fileSize($0) > fileSize($1) }
        guard let sideband = candidates.first, fileSize(sideband) >= minimumSize else {
            throw SessionRecoveryError.mediaTooSmall
        }

        let recoveredURL = finalizedURL.appendingPathExtension("recovered")
        if FileManager.default.fileExists(atPath: recoveredURL.path) {
            try FileManager.default.removeItem(at: recoveredURL)
        }
        try FileManager.default.copyItem(at: sideband, to: recoveredURL)
        if FileManager.default.fileExists(atPath: finalizedURL.path) {
            _ = try FileManager.default.replaceItemAt(finalizedURL, withItemAt: recoveredURL)
        } else {
            try FileManager.default.moveItem(at: recoveredURL, to: finalizedURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalizedURL.path)
        return finalizedURL
    }

    private func recoveredFrameCandidates(in directory: URL) -> [FrameCandidate] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { url -> FrameCandidate? in
            guard url.pathExtension.lowercased() == "jpg" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            let components = stem.split(separator: "-", maxSplits: 2).map(String.init)
            guard components.count == 3,
                  let tMs = Int(components[1]),
                  let kind = FrameKind(rawValue: components[2]) else { return nil }
            return FrameCandidate(file: "frames/\(url.lastPathComponent)", tMs: tMs, kind: kind)
        }
        .sorted { $0.tMs < $1.tMs }
    }
}

private enum SessionRecoveryError: LocalizedError {
    case mediaTooSmall
    case outputNotPlayable

    var errorDescription: String? {
        switch self {
        case .mediaTooSmall: return "복구할 미디어 조각이 충분하지 않습니다."
        case .outputNotPlayable: return "복구된 영상을 재생할 수 없습니다."
        }
    }
}
