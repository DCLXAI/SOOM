import AppKit
import AVFoundation
import ShowTellCore
import SwiftUI

@MainActor
final class RecordingOverlayState: ObservableObject {
    @Published var elapsedMs = 0
    @Published var isPaused = false
    @Published var microphoneActive = true
    @Published var microphoneLevel = 0.0
    @Published var realtimeState: RealtimeTranscriptionState = .disabled
    @Published var liveCaption = ""
    @Published var healthWarning: String?
}

struct RecordingOverlayView: View {
    @ObservedObject var state: RecordingOverlayState
    let cameraSession: AVCaptureSession
    let cameraEnabled: Bool
    let onStop: () -> Void
    let onPause: () -> Void
    let onCancel: () -> Void

    private var timerText: String {
        let totalSeconds = state.elapsedMs / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    var body: some View {
        VStack(spacing: 12) {
            if cameraEnabled {
                ZStack(alignment: .topTrailing) {
                    CameraPreviewView(session: cameraSession)
                        .frame(width: 220, height: 220)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.soomVioletSoft, lineWidth: 5))
                        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)

                    HStack(spacing: 5) {
                        MicrophoneBars(level: state.microphoneLevel, compact: true)
                        Image(systemName: state.microphoneActive ? "mic.fill" : "mic.slash.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(10)
                }
            }

            if let healthWarning = state.healthWarning {
                Label(healthWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .frame(width: 338, alignment: .leading)
                    .background(.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(state.realtimeState.isListening ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.realtimeState.overlayLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(state.liveCaption.isEmpty ? "말하면 한국어 자막이 여기에 표시됩니다" : state.liveCaption)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.liveCaption.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: 338, alignment: .topLeading)
            .frame(minHeight: 52, alignment: .topLeading)
            .background(.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.black.opacity(0.07)))
            .shadow(color: .black.opacity(0.13), radius: 10, y: 4)

            HStack(spacing: 0) {
                Button(action: onStop) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.soomCoral)
                        .frame(width: 24, height: 24)
                        .shadow(color: Color.red.opacity(0.24), radius: 5)
                }
                .buttonStyle(.plain)
                .help("녹화 저장 및 종료")

                Text(timerText)
                    .font(.title2.weight(.medium).monospacedDigit())
                    .frame(width: 78)

                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: 38)
                    .padding(.horizontal, 10)

                Button(action: onPause) {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.isPaused ? "녹화 재개" : "녹화 일시정지")

                Button(action: onCancel) {
                    Image(systemName: "trash")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("녹화 취소 및 삭제")
            }
            .foregroundStyle(.black.opacity(0.86))
            .padding(.horizontal, 18)
            .frame(height: 72)
            .background(.white.opacity(0.98), in: Capsule())
            .overlay(Capsule().stroke(Color.soomViolet.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 9)
        }
        .frame(width: 350, height: cameraEnabled ? 378 : 146)
        .contentShape(Rectangle())
    }
}

struct MicrophoneBars: View {
    let level: Double
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 1.5 : 2) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(indexThreshold(index) <= level ? Color.green : Color.secondary.opacity(0.28))
                    .frame(width: compact ? 2 : 3, height: barHeight(index))
            }
        }
        .frame(width: compact ? 13 : 20, height: compact ? 12 : 18)
        .accessibilityLabel("마이크 입력 레벨")
        .accessibilityValue("\(Int(level * 100))퍼센트")
    }

    private func indexThreshold(_ index: Int) -> Double { Double(index + 1) / 5 }
    private func barHeight(_ index: Int) -> CGFloat {
        let heights: [CGFloat] = compact ? [5, 9, 12, 7] : [7, 13, 18, 10]
        return heights[index]
    }
}

@MainActor
final class RecordingPanelController: NSObject, NSWindowDelegate {
    let state = RecordingOverlayState()
    private let panel: NSPanel
    private let display: DisplayDescriptor
    private let cameraDiameter: CGFloat = 220

    var onOverlayChanged: ((RectValue) -> Void)?

    init(
        cameraSession: AVCaptureSession,
        cameraEnabled: Bool,
        display: DisplayDescriptor,
        onStop: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.display = display
        let panelHeight: CGFloat = cameraEnabled ? 378 : 146
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // This panel is a local recording control, not recorded content. The
        // ScreenCaptureKit filter also excludes SOOM's process, while this
        // window-level guard prevents a stale or system-provided filter from
        // baking the face preview, captions, and controls into the video.
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(
            rootView: RecordingOverlayView(
                state: state,
                cameraSession: cameraSession,
                cameraEnabled: cameraEnabled,
                onStop: onStop,
                onPause: onPause,
                onCancel: onCancel
            )
        )
    }

    func show() {
        let selectedScreen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }) ?? NSScreen.main
        if let screen = selectedScreen {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(
                CGPoint(
                    x: visible.minX + 34,
                    y: visible.minY + 34
                )
            )
        }
        panel.orderFrontRegardless()
        notifyOverlayPosition()
    }

    func close() {
        panel.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        notifyOverlayPosition()
    }

    private func notifyOverlayPosition() {
        guard panel.frame.height > 200 else { return }
        guard let screen = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }) else { return }
        let cameraMinX = panel.frame.minX + (panel.frame.width - cameraDiameter) / 2
        let cameraMinY = panel.frame.minY + panel.frame.height - cameraDiameter
        let x = (cameraMinX - screen.frame.minX) / screen.frame.width
        let y = 1 - ((cameraMinY - screen.frame.minY + cameraDiameter) / screen.frame.height)
        let width = cameraDiameter / screen.frame.width
        let height = cameraDiameter / screen.frame.height
        onOverlayChanged?(
            RectValue(
                x: min(max(x, 0), 1 - width),
                y: min(max(y, 0), 1 - height),
                width: width,
                height: height
            )
        )
    }
}
