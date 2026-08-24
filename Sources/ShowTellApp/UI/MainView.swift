import AppKit
import ShowTellCore
import ShowTellShare
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SOOMHeader(phase: model.phase)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Group {
                switch model.phase {
                case .setup: SetupView(model: model)
                case .idle, .selecting: ReadyView(model: model)
                case .countdown: CountdownView(model: model)
                case .recording, .paused: RecordingInProgressView(model: model)
                case .finalizing, .processing: ProcessingView(model: model)
                case .recorded: LocalRecordingView(model: model)
                case .complete: ResultView(model: model)
                case .failed: FailureView(model: model)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.soomCanvas)
        .tint(Color.soomViolet)
        .frame(width: 390, height: 680)
        .onAppear { model.refreshSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSetup()
        }
    }
}

private struct SOOMHeader: View {
    let phase: AppPhase

    var body: some View {
        HStack(spacing: 12) {
            SOOMWordmark()
            Spacer()
            Label(status.title, systemImage: status.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.88), in: Capsule())
        }
    }

    private var status: (title: String, icon: String, color: Color) {
        switch phase {
        case .setup: return ("설정 필요", "exclamationmark.circle.fill", .orange)
        case .selecting: return ("화면 선택", "display", .soomViolet)
        case .countdown: return ("곧 시작", "timer", .soomViolet)
        case .recording: return ("녹화 중", "record.circle.fill", .soomCoral)
        case .paused: return ("일시정지", "pause.circle.fill", .orange)
        case .finalizing: return ("저장 중", "externaldrive.fill.badge.checkmark", .soomViolet)
        case .processing: return ("AI 처리 중", "sparkles", .soomViolet)
        case .recorded: return ("로컬 저장 완료", "checkmark.circle.fill", .green)
        case .complete: return ("완료", "checkmark.circle.fill", .green)
        case .failed: return ("확인 필요", "exclamationmark.circle.fill", .orange)
        case .idle: return ("준비 완료", "checkmark.circle.fill", .green)
        }
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var permissions: PermissionsManager

    init(model: AppModel) {
        self.model = model
        permissions = model.permissions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SOOM을 시작해 볼까요?")
                        .font(.title2.weight(.bold))
                    Text("화면을 보여주고 말하면 AI 작업으로 정리합니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    PermissionRow(icon: "display", title: "화면 녹화", state: permissions.screen) {
                        permissions.openPrivacySettings("screen")
                    }
                    Divider().padding(.leading, 48)
                    PermissionRow(icon: "video.fill", title: "카메라", state: permissions.camera) {
                        permissions.openPrivacySettings("camera")
                    }
                    Divider().padding(.leading, 48)
                    PermissionRow(icon: "mic.fill", title: "마이크", state: permissions.microphone) {
                        permissions.openPrivacySettings("microphone")
                    }
                    Divider().padding(.leading, 48)
                    PermissionRow(icon: "cursorarrow.click", title: "입력 모니터링", state: permissions.inputMonitoring, isOptional: true) {
                        permissions.openPrivacySettings("input")
                    }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 18))

                Button {
                    Task { await model.requestAllPermissions() }
                } label: {
                    Label("권한 요청 및 상태 확인", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Label("OpenAI API 키 · 선택", systemImage: "key.fill")
                        .font(.subheadline.weight(.semibold))
                    HStack {
                        SecureField("sk-…", text: $model.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button(model.hasAPIKey ? "교체" : "저장") { model.saveAPIKey() }
                            .buttonStyle(.borderedProminent)
                    }
                    if model.hasAPIKey {
                        Button("저장된 API 키 삭제", role: .destructive, action: model.clearAPIKey)
                            .font(.caption)
                    }
                    Text("키가 없어도 녹화됩니다. TaskSpec을 만들 때만 Keychain의 키를 사용합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 18))

                if Bundle.main.object(forInfoDictionaryKey: "SOOMSigningMode") as? String == "adhoc" {
                    Label {
                        Text("개발 빌드는 새로 빌드할 때 화면·입력 권한을 다시 허용해야 합니다.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "hammer.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let state: PermissionState
    var isOptional = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.soomViolet)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                if isOptional {
                    Text("클릭·타이핑 구간 근거용 · 허용하지 않아도 녹화 가능")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state == .granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("설정", action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }
}

private struct ReadyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var picker: CaptureSourcePicker
    @ObservedObject private var camera: CameraCaptureController
    @State private var showCaptureMenu = false
    @State private var showAgentSettings = false
    @State private var showSessionLibrary = false

    init(model: AppModel) {
        self.model = model
        picker = model.picker
        camera = model.camera
    }

    var body: some View {
        VStack(spacing: 12) {
            Button { showCaptureMenu.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.selectedCaptureIcon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedCaptureTitle).font(.subheadline.weight(.semibold))
                        Text(model.selectedDisplayLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("선택").font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .foregroundStyle(Color.soomViolet)
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background(Color.soomVioletSoft, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCaptureMenu, arrowEdge: .trailing) {
                CaptureTypeMenu(model: model, isPresented: $showCaptureMenu)
            }

            RecorderSettingRow(
                icon: "video.fill",
                title: camera.cameraName,
                subtitle: model.cameraEnabled ? "Facecam을 영상에 함께 녹화" : "Facecam 끔",
                isOn: $model.cameraEnabled
            ) {
                if model.cameraEnabled && camera.isRunning {
                    CameraPreviewView(session: camera.session)
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                }
            }
            .disabled(model.isCameraOnly)

            RecorderStatusRow(
                icon: "mic.fill",
                title: "기본 마이크",
                subtitle: model.isDefaultMicrophoneMuted
                    ? "macOS 사운드 입력에서 음소거 해제가 필요합니다"
                    : "음성 설명과 TaskSpec 근거",
                status: model.isDefaultMicrophoneMuted ? "Muted" : "On",
                statusColor: model.isDefaultMicrophoneMuted ? .orange : .green
            )

            RecorderSettingRow(
                icon: "waveform.badge.mic",
                title: "AI 실시간 자막",
                subtitle: model.liveAssistEnabled ? "한국어·영어를 듣는 중" : "종료 후에만 AI 처리",
                isOn: $model.liveAssistEnabled
            ) { EmptyView() }
            .disabled(!model.hasAPIKey)

            if !model.hasAPIKey {
                Label("API 키가 없어 실시간 자막은 꺼져 있습니다. 녹화는 정상 저장됩니다.", systemImage: "lock.open.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("녹화 저장 방식", systemImage: model.deliveryMode == .localOnly ? "internaldrive.fill" : "link")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(model.deliveryMode.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if model.hostedShareAvailable {
                    Picker("저장 방식", selection: $model.deliveryMode) {
                        ForEach(DeliveryMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                } else {
                    Label("이 공개판은 영상과 세션을 이 Mac에만 보관합니다.", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.soomControl, in: RoundedRectangle(cornerRadius: 17))

            if let screenshot = model.lastScreenshotURL {
                Label("저장됨 · \(screenshot.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            if let message = model.recordingPreflightMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.recordingPreflightTitle)
                            .font(.caption.weight(.bold))
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(
                            model.recordingPreflightActionTitle,
                            action: model.resolveRecordingPreflightIssue
                        )
                            .font(.caption.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            }

            Button {
                Task { await model.startRecording() }
            } label: {
                HStack {
                    Image(systemName: "record.circle")
                    Text(model.phase == .selecting ? "화면을 선택하는 중…" : "녹화 시작")
                    Spacer()
                    Text("⌥⌘R").font(.caption.weight(.bold)).opacity(0.78)
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.soomCoral, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .soomCoral.opacity(0.22), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .selecting)

            Divider().padding(.top, 4)

            Button {
                model.refreshSessionLibrary()
                showSessionLibrary = true
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("녹화 보관함")
                    Spacer()
                    Text("\(model.sessionLibrary.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Color.soomControl, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showSessionLibrary) {
                SessionLibraryView(model: model, isPresented: $showSessionLibrary)
            }

            HStack {
                BottomTool(icon: "folder.fill", title: "프로젝트", action: model.chooseProjectFolder)
                Spacer()
                BottomTool(icon: "square.and.arrow.down.fill", title: "내보내기", action: model.chooseExportFolder)
                Spacer()
                BottomTool(icon: "slider.horizontal.3", title: "Agent 설정") { showAgentSettings.toggle() }
                    .popover(isPresented: $showAgentSettings, arrowEdge: .bottom) {
                        AgentSettingsPopover(model: model)
                    }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .padding(16)
        .soomCard()
    }
}

private struct CaptureTypeMenu: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CaptureMenuRow(
                icon: "display",
                title: "전체 화면",
                detail: model.selectedCaptureMode == .display ? "선택됨" : "선택",
                active: true
            ) {
                isPresented = false
                Task { await model.chooseCaptureMode(.display) }
            }
            CaptureMenuRow(
                icon: "macwindow",
                title: "특정 윈도우",
                detail: model.selectedCaptureMode == .window ? "선택됨" : "선택",
                active: true
            ) {
                isPresented = false
                Task { await model.chooseCaptureMode(.window) }
            }
            CaptureMenuRow(
                icon: "rectangle.dashed",
                title: "사용자 지정 영역",
                detail: model.selectedCaptureMode == .region ? "선택됨" : "드래그",
                active: true
            ) {
                isPresented = false
                Task { await model.chooseCaptureMode(.region) }
            }
            Text("더 보기")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            CaptureMenuRow(
                icon: "video.fill",
                title: "카메라만",
                detail: model.selectedCaptureMode == .cameraOnly ? "선택됨" : "선택",
                active: true
            ) {
                isPresented = false
                Task { await model.chooseCaptureMode(.cameraOnly) }
            }
            CaptureMenuRow(icon: "camera.fill", title: "스크린샷", detail: "현재 소스 · PNG", active: true) {
                isPresented = false
                Task { await model.takeScreenshot() }
            }
        }
        .padding(10)
        .frame(width: 284)
    }
}

private struct CaptureMenuRow: View {
    let icon: String
    let title: String
    let detail: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                Text(title)
                Spacer()
                Text(detail).font(.caption.weight(.semibold))
            }
            .foregroundStyle(active ? Color.soomViolet : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(active ? Color.soomVioletSoft : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!active)
    }
}

private struct RecorderSettingRow<Accessory: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            accessory()
            Image(systemName: icon).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(Color.soomControl, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct RecorderStatusRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let status: String
    let statusColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(statusColor, in: Capsule())
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(Color.soomControl, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct BottomTool: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .frame(width: 32, height: 32)
                    .background(Color.soomControl, in: Circle())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct AgentSettingsPopover: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent 전달 설정").font(.headline)
                SettingValue(label: "프로젝트", value: model.projectURL?.lastPathComponent ?? "선택 안 함")
                SettingValue(label: "내보내기", value: model.exportDirectory.lastPathComponent)
                Picker("녹화 품질", selection: $model.recordingQuality) {
                    ForEach(RecordingQuality.allCases, id: \.self) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                Toggle("진단 로그 저장에 동의", isOn: $model.diagnosticsConsent)
                    .font(.subheadline)
                Button("진단 패키지 내보내기", action: model.exportDiagnosticBundle)
                    .disabled(!model.diagnosticsConsent)

                if model.hostedShareAvailable {
                    Divider()
                    Text("Share 서버").font(.headline)
                    TextField("https://share.example.com", text: $model.shareServerURL)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Recorder 업로드 토큰", text: $model.shareUploadToken)
                        .textFieldStyle(.roundedBorder)
                    Picker("공개 범위", selection: $model.sharePrivacy) {
                        ForEach(SharePrivacy.allCases) { privacy in Text(privacy.title).tag(privacy) }
                    }
                    if model.sharePrivacy == .password {
                        SecureField("공유 비밀번호 (4자 이상)", text: $model.sharePassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("링크 만료", selection: $model.shareExpirationDays) {
                        Text("만료 없음").tag(0)
                        Text("1일").tag(1)
                        Text("7일").tag(7)
                        Text("30일").tag(30)
                    }
                    Toggle("원본 다운로드 허용", isOn: $model.shareAllowDownload)
                        .font(.subheadline)
                    Button("공유 설정 저장", action: model.saveShareSettings)
                        .buttonStyle(.borderedProminent)
                    if let error = model.shareError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Divider()
                    Label("Hosted Share는 보안 재설계가 끝날 때까지 공개판에서 비활성화됩니다.", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .frame(width: 320, height: 520)
    }
}

private struct SettingValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1) }
            .font(.subheadline)
    }
}

private struct SessionLibraryView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""

    private var filtered: [SessionLibraryItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return model.sessionLibrary }
        return model.sessionLibrary.filter { item in
            item.id.lowercased().contains(text)
                || item.captureLabel.lowercased().contains(text)
                || (item.projectName?.lowercased().contains(text) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("녹화 보관함").font(.title3.weight(.bold))
                Spacer()
                Button("닫기") { isPresented = false }
            }
            TextField("프로젝트·화면·세션 ID 검색", text: $query)
                .textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                ContentUnavailableView("보존된 녹화가 없습니다", systemImage: "video.slash")
            } else {
                List(filtered) { item in
                    SessionLibraryRow(item: item) {
                        isPresented = false
                        model.openLibrarySession(id: item.id)
                    } onRetry: {
                        isPresented = false
                        Task { await model.reprocessLibrarySession(id: item.id) }
                    } onDelete: {
                        Task { await model.deleteLibrarySession(id: item.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(18)
        .frame(width: 560, height: 480)
        .onAppear { model.refreshSessionLibrary() }
    }
}

private struct SessionLibraryRow: View {
    let item: SessionLibraryItem
    let onOpen: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.hasRecording ? "play.rectangle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.state == .completed ? .green : Color.soomViolet)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.projectName ?? item.captureLabel).font(.subheadline.weight(.semibold))
                    if item.recovered {
                        Text("복구됨").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                    }
                }
                Text("\(item.createdAt) · \(durationText)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("열기", action: onOpen).controlSize(.small)
            if item.state != .completed, item.hasRecording {
                Button("재처리", action: onRetry).controlSize(.small)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var durationText: String {
        guard let durationMs = item.durationMs else { return item.state.rawValue }
        return String(format: "%d:%02d", durationMs / 60_000, (durationMs / 1_000) % 60)
    }
}

private struct CountdownView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            SOOMMark().frame(width: 58, height: 58)
            Text("준비하세요").font(.title2.weight(.bold))
            Text("\(max(model.countdownSeconds, 1))")
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .foregroundStyle(Color.soomViolet)
                .contentTransition(.numericText())
            Text("카메라와 설명할 화면을 확인하세요.")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct RecordingInProgressView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            SOOMMark(color: .soomCoral).frame(width: 72, height: 72)
            Text("녹화 중").font(.title2.weight(.bold))
            Text("Facecam 옆의 컨트롤에서 일시정지하거나 완료할 수 있습니다.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.liveAssistEnabled {
                Text(model.liveTranscript.isEmpty ? model.realtimeState.overlayLabel : model.liveTranscript)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
            Button("녹화 저장 및 종료") { Task { await model.stopRecording() } }
                .buttonStyle(.borderedProminent)
                .tint(Color.soomCoral)
            Spacer()
        }
    }
}

private struct ProcessingView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().stroke(Color.soomVioletSoft, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.03, model.progressFraction))
                    .stroke(Color.soomViolet, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                SOOMMark(showsRecordingDot: false).frame(width: 48, height: 48)
            }
            .frame(width: 126, height: 126)
            Text(model.phase == .finalizing ? "녹화를 정리하는 중" : model.progressStage)
                .font(.title3.weight(.bold)).multilineTextAlignment(.center)
            Text("음성·클릭·화면 근거를 한국어 작업으로 바꾸고 있습니다.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("\(Int(model.progressFraction * 100))%")
                .font(.caption.weight(.bold)).foregroundStyle(Color.soomViolet)
            Spacer()
        }
    }
}

private struct LocalRecordingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("녹화를 이 Mac에 저장했습니다", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)
                Text("영상은 안전하게 보존되어 있습니다. API 키를 연결하면 언제든 한국어 TaskSpec을 만들 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let player = model.recordingPlayer {
                    RecordingPlayerView(player: player)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                if model.hasAPIKey {
                    Button {
                        Task { await model.retryProcessing() }
                    } label: {
                        Label("한국어 TaskSpec 만들기", systemImage: "sparkles")
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("OpenAI BYOK 연결", systemImage: "key.fill")
                            .font(.subheadline.weight(.semibold))
                        HStack {
                            SecureField("sk-…", text: $model.apiKey)
                                .textFieldStyle(.roundedBorder)
                            Button("저장", action: model.saveAPIKey)
                                .buttonStyle(.borderedProminent)
                        }
                        Text("키는 Keychain에만 저장되며 TaskSpec 생성 요청에만 사용됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color.soomVioletSoft, in: RoundedRectangle(cornerRadius: 16))
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("원본 보기", action: model.revealSession)
                    Spacer()
                    Button("새 녹화", action: model.recordAgain)
                }
            }
            .padding(16)
        }
        .soomCard()
    }
}

private struct ResultView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Agent 작업 준비 완료", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.bold)).foregroundStyle(.green)
                Text(model.lastTaskSpec?.goal ?? "한국어 TaskSpec을 만들었습니다")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)

                if let player = model.recordingPlayer {
                    RecordingPlayerView(player: player)
                        .frame(height: 152)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                TaskListCard(model: model)

                if let warning = model.errorMessage {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }

                if model.hostedShareAvailable {
                    ShareResultCard(model: model)
                }

                Button(action: model.copyAgentTask) {
                    Label("Codex / Claude Code용 작업 복사", systemImage: "doc.on.doc.fill")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.borderedProminent)

                HStack {
                    Button("Finder", action: model.revealLastExport)
                    Button("원본", action: model.revealSession)
                    Spacer()
                    Button("새 녹화", action: model.recordAgain)
                }
            }
            .padding(16)
        }
        .soomCard()
    }
}

private struct ShareResultCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.shareURL == nil ? "공유 페이지" : "공유 링크 준비됨", systemImage: model.shareURL == nil ? "link.badge.plus" : "link.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.shareProgress > 0, model.shareProgress < 1 {
                    Text("\(Int(model.shareProgress * 100))%")
                        .font(.caption.weight(.bold)).foregroundStyle(Color.soomViolet)
                }
            }
            if !model.shareStatus.isEmpty {
                Text(model.shareStatus).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("기본값은 Local Only입니다. 이 녹화만 선택해서 업로드할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.shareError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if model.shareProgress > 0, model.shareProgress < 1 {
                ProgressView(value: model.shareProgress).tint(Color.soomViolet)
            }
            HStack {
                if model.shareURL == nil {
                    Button("이 녹화 공유", action: model.shareCurrentRecording)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("링크 복사", action: model.copyShareLink)
                        .buttonStyle(.borderedProminent)
                    Button("브라우저에서 열기", action: model.openShareLink)
                }
            }
        }
        .padding(14)
        .background(Color.soomVioletSoft, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct TaskListCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.lastTaskSpec?.summary ?? "").font(.subheadline)
            ForEach(Array((model.lastTaskSpec?.tasks ?? []).enumerated()), id: \.offset) { index, task in
                TaskResultRow(index: index, task: task) {
                    if let evidence = task.evidence.first {
                        model.seekToEvidence(milliseconds: evidence.tMs)
                    }
                }
            }
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TaskResultRow: View {
    let index: Int
    let task: TaskSpec.Task
    let showEvidence: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.soomViolet, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.subheadline.weight(.semibold))
                Text(task.change.instruction).font(.caption).foregroundStyle(.secondary)
                if let evidence = task.evidence.first {
                    Button("근거 \(evidence.tMs / 1_000)초 보기", systemImage: "play.circle.fill", action: showEvidence)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.soomViolet)
                }
            }
        }
    }
}

private struct FailureView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("처리를 완료하지 못했습니다").font(.title3.weight(.bold))
            Text(model.errorMessage ?? "알 수 없는 오류")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.canRetryProcessing {
                Button("TaskSpec 다시 생성") { Task { await model.retryProcessing() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("보존된 세션 열기", action: model.revealSession)
            }
            Button("새 녹화") { model.recordAgain() }
            Spacer()
        }
        .padding(20)
        .soomCard()
    }
}
