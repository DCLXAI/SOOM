import AppKit
import SwiftUI

@main
struct SOOMApp: App {
    @NSApplicationDelegateAdaptor(SOOMAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
                .onAppear { appDelegate.model = model }
        } label: {
            SOOMMark(color: model.isCapturing ? .soomCoral : .primary, showsRecordingDot: model.isCapturing)
                .frame(width: 17, height: 17)
                .onAppear { appDelegate.model = model }
        }
    }
}

@MainActor
final class SOOMAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var awaitingTerminationReply = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.requiresTerminationCoordination else { return .terminateNow }
        guard !awaitingTerminationReply else { return .terminateLater }
        awaitingTerminationReply = true
        Task { @MainActor [weak self] in
            let shouldTerminate = await model.prepareForTermination()
            self?.awaitingTerminationReply = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isCapturing {
            Button(model.phase == .paused ? "녹화 재개" : "녹화 일시정지") {
                model.togglePause()
            }
            Button("녹화 저장 및 종료") {
                Task { await model.stopRecording() }
            }
            Button("녹화 취소 및 삭제") {
                Task { await model.cancelRecording() }
            }
            Divider()
        } else {
            Button("녹화 시작   ⌥⌘R") {
                Task { await model.startRecording() }
            }
            .disabled(!model.startButtonEnabled)
            Button("녹화 화면 선택…") {
                Task { await model.chooseCaptureSource() }
            }
            .disabled(!model.startButtonEnabled)
            Divider()
            Toggle("카메라", isOn: $model.cameraEnabled)
            Toggle("AI 실시간 자막", isOn: $model.liveAssistEnabled)
        }

        Button("SOOM 열기") {
            model.showMainWindow()
        }
        Divider()
        Button("종료") { NSApp.terminate(nil) }
    }
}
