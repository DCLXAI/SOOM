import AppKit
import AVFoundation
import CoreGraphics
import ShowTellCore

enum PermissionState: String {
    case granted
    case denied
    case notDetermined

    var label: String {
        switch self {
        case .granted: return "허용됨"
        case .denied: return "필요함"
        case .notDetermined: return "확인 필요"
        }
    }
}

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var screen: PermissionState = .notDetermined
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var camera: PermissionState = .notDetermined
    @Published private(set) var inputMonitoring: PermissionState = .notDetermined

    var allGranted: Bool {
        screen == .granted && microphone == .granted && camera == .granted && inputMonitoring == .granted
    }

    /// Permissions required to produce a playable local recording. Input
    /// Monitoring enriches AI evidence, but must never block recording.
    func canRecord(cameraEnabled: Bool) -> Bool {
        recordingDecision(cameraEnabled: cameraEnabled).canRecord
    }

    func missingRecordingPermissions(cameraEnabled: Bool) -> [String] {
        recordingDecision(cameraEnabled: cameraEnabled).missing.map { permission in
            switch permission {
            case .screenCapture: return "화면 녹화"
            case .microphone: return "마이크"
            case .camera: return "카메라"
            }
        }
    }

    func refresh() {
        screen = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        inputMonitoring = CGPreflightListenEventAccess() ? .granted : .notDetermined
        microphone = state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        camera = state(for: AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    func requestCamera() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
    }

    func openPrivacySettings(_ kind: String) {
        let pane: String
        switch kind {
        case "screen": pane = "Privacy_ScreenCapture"
        case "microphone": pane = "Privacy_Microphone"
        case "camera": pane = "Privacy_Camera"
        default: pane = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func state(for status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private func recordingDecision(cameraEnabled: Bool) -> RecordingPermissionDecision {
        LocalRecordingPolicy.permissions(
            RecordingPermissionSnapshot(
                screenCaptureGranted: screen == .granted,
                microphoneGranted: microphone == .granted,
                cameraGranted: camera == .granted,
                inputMonitoringGranted: inputMonitoring == .granted
            ),
            cameraRequired: cameraEnabled
        )
    }
}
