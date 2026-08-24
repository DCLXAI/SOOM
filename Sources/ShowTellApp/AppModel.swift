import AppKit
import AVFoundation
import Foundation
import ShowTellCore
import ShowTellShare
import SwiftUI
import UniformTypeIdentifiers

enum AppPhase: String {
    case setup
    case idle
    case selecting
    case countdown
    case recording
    case paused
    case finalizing
    case processing
    case recorded
    case complete
    case failed
}

struct SessionLibraryItem: Identifiable, Equatable {
    let id: String
    let createdAt: String
    let state: SessionState
    let durationMs: Int?
    let captureLabel: String
    let projectName: String?
    let recovered: Bool
    let hasRecording: Bool
}

@MainActor
final class AppModel: ObservableObject {
    /// The hosted service is intentionally unavailable in the open-source,
    /// local-first build until its multi-user authorization and retention model
    /// has completed a separate security review.
    static let hostedShareEnabled = false

    @Published private(set) var phase: AppPhase = .setup
    @Published var apiKey = ""
    @Published var liveAssistEnabled: Bool {
        didSet { UserDefaults.standard.set(liveAssistEnabled, forKey: "liveAssistEnabled") }
    }
    @Published var cameraEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cameraEnabled, forKey: "cameraEnabled")
            Task { @MainActor [weak self] in await self?.updateCameraPreview() }
        }
    }
    @Published var recordingQuality: RecordingQuality {
        didSet { UserDefaults.standard.set(recordingQuality.rawValue, forKey: "recordingQuality") }
    }
    @Published var diagnosticsConsent: Bool {
        didSet { UserDefaults.standard.set(diagnosticsConsent, forKey: "diagnosticsConsent") }
    }
    @Published var deliveryMode: DeliveryMode = .localOnly {
        didSet { UserDefaults.standard.set(deliveryMode.rawValue, forKey: "deliveryMode") }
    }
    @Published var shareServerURL = "" {
        didSet { UserDefaults.standard.set(shareServerURL, forKey: "shareServerURL") }
    }
    @Published var shareUploadToken = ""
    @Published var sharePrivacy: SharePrivacy = .private {
        didSet { UserDefaults.standard.set(sharePrivacy.rawValue, forKey: "sharePrivacy") }
    }
    @Published var sharePassword = ""
    @Published var shareExpirationDays = 7 {
        didSet { UserDefaults.standard.set(shareExpirationDays, forKey: "shareExpirationDays") }
    }
    @Published var shareAllowDownload = false {
        didSet { UserDefaults.standard.set(shareAllowDownload, forKey: "shareAllowDownload") }
    }
    @Published private(set) var projectURL: URL?
    @Published private(set) var exportDirectory: URL
    @Published private(set) var progressStage = ""
    @Published private(set) var progressFraction = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastTaskSpec: TaskSpec?
    @Published private(set) var lastExportDirectory: URL?
    @Published private(set) var lastScreenshotURL: URL?
    @Published private(set) var recordingPlayer: AVPlayer?
    @Published private(set) var realtimeState: RealtimeTranscriptionState = .disabled
    @Published private(set) var liveTranscript = ""
    @Published private(set) var countdownSeconds = 0
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var recordingWarning: String?
    @Published private(set) var recordingPreflightMessage: String?
    @Published private(set) var recordingPreflightTitle = ""
    @Published private(set) var recordingPreflightActionTitle = ""
    @Published private(set) var isDefaultMicrophoneMuted = false
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var sessionLibrary: [SessionLibraryItem] = []
    @Published private(set) var shareURL: URL?
    @Published private(set) var shareProgress = 0.0
    @Published private(set) var shareStatus = ""
    @Published private(set) var shareError: String?

    let permissions = PermissionsManager()
    let picker = CaptureSourcePicker()
    let camera = CameraCaptureController()

    private let store = SessionStore.shared
    private let worker = WorkerRunner()
    private let hotKey = GlobalHotKey()
    private let environmentMonitor = CaptureEnvironmentMonitor()
    private let shareUploader = ShareUploadClient()
    private var currentHandle: SessionHandle?
    private var recorder: ScreenRecorder?
    private var realtimeClient: RealtimeTranscriptionClient?
    private var clock: SessionClock?
    private var overlayPanel: RecordingPanelController?
    private var mainWindowController: NSWindowController?
    private var elapsedTimer: Timer?
    private var isStopping = false
    private var persistedAPIKey = ""
    private var lastHealthCheckpointMs = -1_000
    private let maximumDurationMs = 180_000
    private var libraryHandles: [String: SessionHandle] = [:]
    private var shareMediaTasks: [String: Task<ShareUploadReceipt, Error>] = [:]

    init() {
        if UserDefaults.standard.object(forKey: "liveAssistEnabled") == nil {
            liveAssistEnabled = false
        } else {
            liveAssistEnabled = UserDefaults.standard.bool(forKey: "liveAssistEnabled")
        }
        if UserDefaults.standard.object(forKey: "cameraEnabled") == nil {
            cameraEnabled = true
        } else {
            cameraEnabled = UserDefaults.standard.bool(forKey: "cameraEnabled")
        }
        recordingQuality = RecordingQuality(
            rawValue: UserDefaults.standard.string(forKey: "recordingQuality") ?? ""
        ) ?? .standard1080p
        diagnosticsConsent = UserDefaults.standard.bool(forKey: "diagnosticsConsent")
        deliveryMode = .localOnly
        shareServerURL = UserDefaults.standard.string(forKey: "shareServerURL")
            ?? "https://soom-share-ai.soonsooo.chatgpt.site"
        shareUploadToken = KeychainStore.loadShareToken() ?? ""
        sharePrivacy = SharePrivacy(rawValue: UserDefaults.standard.string(forKey: "sharePrivacy") ?? "") ?? .private
        shareExpirationDays = UserDefaults.standard.object(forKey: "shareExpirationDays") == nil
            ? 7
            : UserDefaults.standard.integer(forKey: "shareExpirationDays")
        shareAllowDownload = UserDefaults.standard.bool(forKey: "shareAllowDownload")
        let storedAPIKey = KeychainStore.loadAPIKey() ?? ""
        apiKey = storedAPIKey
        persistedAPIKey = storedAPIKey
        let defaultExport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/SOOM Exports", isDirectory: true)
        if let saved = UserDefaults.standard.string(forKey: "exportDirectory") {
            exportDirectory = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            exportDirectory = defaultExport
        }
        if let project = UserDefaults.standard.string(forKey: "projectDirectory") {
            projectURL = URL(fileURLWithPath: project, isDirectory: true)
        }

        permissions.refresh()
        _ = try? store.migrateLegacyEventPrivacy()
        isDefaultMicrophoneMuted = MicrophoneDeviceState.defaultInputIsMuted() == true
        if let recoverable = try? store.latestRecoverableSession(),
           recoverable.manifest.sessionId != UserDefaults.standard.string(forKey: "dismissedRecoverySessionId") {
            currentHandle = recoverable
        }
        applyReadyPhase()
        let lastDisplayID = UInt32(UserDefaults.standard.integer(forKey: "lastDisplayID"))
        if lastDisplayID != 0 {
            Task { @MainActor [weak picker] in await picker?.restore(displayID: lastDisplayID) }
        }
        hotKey.register { [weak self] in
            Task { @MainActor in self?.handleHotKey() }
        }
        Task { @MainActor [weak self] in self?.showMainWindow() }
        Task { @MainActor [weak self] in await self?.updateCameraPreview() }
        Task { @MainActor [weak self] in await self?.recoverInterruptedSessionsAtLaunch() }
        if Self.hostedShareEnabled {
            Task { @MainActor [weak self] in await self?.resumePendingShareUploadsAtLaunch() }
        }
        refreshSessionLibrary()
    }

    var isCapturing: Bool { phase == .recording || phase == .paused }

    private var localRecordingLifecyclePhase: LocalRecordingLifecyclePhase {
        switch phase {
        case .recording, .paused:
            return .capturing
        case .finalizing:
            return .finalizing
        case .processing:
            return .processingTaskSpec
        case .recorded, .complete:
            return .mediaSaved
        case .setup, .idle, .selecting, .countdown, .failed:
            return .inactive
        }
    }

    var requiresTerminationCoordination: Bool {
        LocalRecordingPolicy.terminationAction(for: localRecordingLifecyclePhase) != .terminateImmediately
    }

    var hasAPIKey: Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == persistedAPIKey
    }

    var hostedShareAvailable: Bool { Self.hostedShareEnabled }

    var startButtonEnabled: Bool {
        ![.selecting, .countdown, .recording, .paused, .finalizing, .processing].contains(phase)
    }

    var selectedDisplayLabel: String {
        picker.selection?.label ?? "녹화할 소스를 선택하세요"
    }

    var selectedCaptureTitle: String { picker.selection?.mode.title ?? "전체 화면" }
    var selectedCaptureIcon: String { picker.selection?.mode.icon ?? CaptureMode.display.icon }
    var selectedCaptureMode: CaptureMode { picker.selection?.mode ?? .display }
    var isCameraOnly: Bool { selectedCaptureMode == .cameraOnly }

    var canRetryProcessing: Bool {
        guard let currentHandle else { return false }
        return hasAPIKey && sessionArtifactsLookComplete(currentHandle)
    }

    func refreshSetup() {
        permissions.refresh()
        isDefaultMicrophoneMuted = MicrophoneDeviceState.defaultInputIsMuted() == true
        if phase == .setup { applyReadyPhase() }
    }

    func requestAllPermissions() async {
        permissions.requestScreen()
        if cameraEnabled { await permissions.requestCamera() }
        await permissions.requestMicrophone()
        permissions.refresh()
        applyReadyPhase()
    }

    func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "OpenAI API 키를 입력해 주세요."
            return
        }
        do {
            try KeychainStore.saveAPIKey(trimmed)
            apiKey = trimmed
            persistedAPIKey = trimmed
            errorMessage = nil
            applyReadyPhase()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAPIKey() {
        do {
            try KeychainStore.deleteAPIKey()
            apiKey = ""
            persistedAPIKey = ""
            liveAssistEnabled = false
            errorMessage = nil
            applyReadyPhase()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseProjectFolder() {
        guard let url = chooseDirectory(title: "선택적 프로젝트 폴더") else { return }
        projectURL = url
        UserDefaults.standard.set(url.path, forKey: "projectDirectory")
    }

    func clearProjectFolder() {
        projectURL = nil
        UserDefaults.standard.removeObject(forKey: "projectDirectory")
    }

    func chooseExportFolder() {
        guard let url = chooseDirectory(title: "TaskSpec 내보내기 폴더") else { return }
        exportDirectory = url
        UserDefaults.standard.set(url.path, forKey: "exportDirectory")
    }

    func chooseCaptureSource() async {
        await chooseCaptureMode(.display)
    }

    func chooseCaptureMode(_ mode: CaptureMode) async {
        guard !isCapturing else { return }
        phase = .selecting
        errorMessage = nil
        let selected: SelectedDisplaySource?
        switch mode {
        case .display: selected = await picker.chooseDisplay()
        case .window: selected = await picker.chooseWindow()
        case .region:
            hideMainWindow()
            selected = await picker.chooseRegion()
            showMainWindow()
        case .cameraOnly:
            cameraEnabled = true
            selected = await picker.selectCameraOnly()
        }
        if let selected {
            UserDefaults.standard.set(Int(selected.display.displayID), forKey: "lastDisplayID")
        }
        phase = .idle
        await updateCameraPreview()
    }

    func takeScreenshot() async {
        guard !isCapturing else { return }
        permissions.refresh()
        guard permissions.screen == .granted else {
            errorMessage = "스크린샷을 위해 화면 녹화 권한이 필요합니다."
            phase = .setup
            return
        }
        phase = .selecting
        errorMessage = nil
        let source: SelectedDisplaySource?
        if let selected = picker.selection, selected.mode != .cameraOnly {
            source = selected
        } else {
            source = await picker.chooseScreenshotSource()
        }
        guard let source else {
            phase = .idle
            return
        }
        do {
            let url = try await ScreenshotCapture.capture(source: source, exportDirectory: exportDirectory)
            lastScreenshotURL = url
            phase = .idle
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
        await updateCameraPreview()
    }

    func startRecording() async {
        guard startButtonEnabled else { return }
        permissions.refresh()
        let needsCamera = cameraEnabled || isCameraOnly
        guard permissions.canRecord(cameraEnabled: needsCamera) else {
            let missing = permissions.missingRecordingPermissions(cameraEnabled: needsCamera).joined(separator: ", ")
            errorMessage = "녹화에 필요한 권한을 확인해 주세요: \(missing). 입력 모니터링은 선택 사항입니다."
            phase = .setup
            showMainWindow()
            return
        }

        isDefaultMicrophoneMuted = MicrophoneDeviceState.defaultInputIsMuted() == true
        if isDefaultMicrophoneMuted {
            recordingPreflightTitle = "기본 마이크가 음소거되어 있습니다"
            recordingPreflightMessage = "macOS 사운드 입력에서 마이크 음소거를 해제한 뒤 다시 녹화해 주세요. 무음 영상은 생성하지 않습니다."
            recordingPreflightActionTitle = "사운드 설정 열기"
            errorMessage = nil
            phase = .idle
            showMainWindow()
            return
        }

        do {
            let storageDirectory = try store.recordingStorageDirectory()
            let availableBytes = availableDiskBytes(at: storageDirectory)
            let requiredBytes = RecordingStoragePolicy.requiredAvailableBytes(
                quality: recordingQuality,
                maximumDurationMs: maximumDurationMs
            )
            guard RecordingStoragePolicy.canStartRecording(
                availableBytes: availableBytes,
                quality: recordingQuality,
                maximumDurationMs: maximumDurationMs
            ) else {
                let available = ByteCountFormatter.string(
                    fromByteCount: availableBytes ?? 0,
                    countStyle: .file
                )
                let required = ByteCountFormatter.string(
                    fromByteCount: requiredBytes,
                    countStyle: .file
                )
                recordingPreflightTitle = "녹화를 시작할 공간이 부족합니다"
                recordingPreflightMessage = "저장 공간이 \(available) 남았습니다. 안정적인 3분 녹화에는 최소 \(required)가 필요합니다. 공간을 확보한 뒤 다시 눌러 주세요."
                recordingPreflightActionTitle = "저장 공간 관리"
                errorMessage = nil
                phase = .idle
                showMainWindow()
                return
            }
            recordingPreflightMessage = nil
            recordingPreflightTitle = ""
            recordingPreflightActionTitle = ""
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
            showMainWindow()
            return
        }

        phase = .selecting
        errorMessage = nil
        let selectedSource: SelectedDisplaySource?
        if let existing = picker.selection {
            selectedSource = existing
        } else {
            selectedSource = await picker.chooseDisplay()
        }
        guard let source = selectedSource else {
            phase = .idle
            return
        }
        if source.mode == .cameraOnly { cameraEnabled = true }
        UserDefaults.standard.set(Int(source.display.displayID), forKey: "lastDisplayID")

        do {
            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let initialOverlay = defaultOverlay(for: source.descriptor)
            let safetyIdentifier = persistentSafetyIdentifier()
            liveTranscript = ""
            microphoneLevel = 0
            let shouldUseLiveAssist = liveAssistEnabled && hasAPIKey
            realtimeState = shouldUseLiveAssist ? .connecting : .disabled
            if cameraEnabled {
                try await camera.start()
            } else {
                camera.stop()
            }

            phase = .countdown
            for second in stride(from: 3, through: 1, by: -1) {
                countdownSeconds = second
                try await Task.sleep(for: .seconds(1))
            }
            countdownSeconds = 0
            let startNs = DispatchTime.now().uptimeNanoseconds
            var handle = try store.create(
                display: source.descriptor,
                overlay: initialOverlay,
                project: ProjectMetadata.read(from: projectURL),
                safetyIdentifier: safetyIdentifier,
                hostStartUptimeNs: startNs,
                captureMode: source.mode,
                captureLabel: source.label,
                quality: recordingQuality,
                diagnosticsConsent: diagnosticsConsent
            )
            let clock = SessionClock(startUptimeNs: startNs)
            let realtimeClient: RealtimeTranscriptionClient?
            if shouldUseLiveAssist {
                let client = RealtimeTranscriptionClient(
                    apiKey: apiKey,
                    safetyIdentifier: safetyIdentifier,
                    onState: { [weak self] state in
                        Task { @MainActor in self?.updateRealtimeState(state) }
                    },
                    onCaption: { [weak self] caption in
                        Task { @MainActor in self?.updateLiveCaption(caption) }
                    }
                )
                realtimeClient = client
                self.realtimeClient = client
                client.start()
            } else {
                realtimeClient = nil
                self.realtimeClient = nil
            }
            let recorder = try ScreenRecorder(
                source: source,
                handle: handle,
                camera: camera,
                clock: clock,
                overlayRect: initialOverlay,
                quality: recordingQuality,
                onMicrophoneSample: { [weak realtimeClient] sampleBuffer in
                    realtimeClient?.append(sampleBuffer)
                },
                onMicrophoneLevel: { [weak self] level in
                    Task { @MainActor in self?.updateMicrophoneLevel(level) }
                },
                onUnexpectedStop: { [weak self] error in
                    Task { @MainActor in await self?.captureStoppedUnexpectedly(error) }
                }
            )
            try await recorder.start()
            try store.update(&handle) { manifest in manifest.state = .recording }

            self.currentHandle = handle
            self.clock = clock
            self.recorder = recorder
            lastHealthCheckpointMs = -1_000
            recordingWarning = nil
            phase = .recording
            hideMainWindow()
            showOverlayPanel(for: source.descriptor)
            environmentMonitor.start(
                displayID: source.descriptor.id,
                microphoneDeviceID: AVCaptureDevice.default(for: .audio)?.uniqueID
            ) { [weak self] event in
                self?.handleCaptureEnvironmentEvent(event)
            }
            startElapsedTimer()
        } catch {
            realtimeClient?.cancel()
            realtimeClient = nil
            camera.stop()
            fail(error)
        }
    }

    func togglePause() {
        guard let recorder else { return }
        if phase == .recording {
            recorder.pause()
            phase = .paused
            overlayPanel?.state.isPaused = true
        } else if phase == .paused {
            recorder.resume()
            phase = .recording
            overlayPanel?.state.isPaused = false
        }
    }

    func stopRecording(processTaskSpec: Bool = true) async {
        guard isCapturing, !isStopping, let recorder, var handle = currentHandle else { return }
        let finalizationPlan = LocalRecordingPolicy.finalizationPlan(
            taskSpecRequested: processTaskSpec,
            hasAPIKey: hasAPIKey
        )
        isStopping = true
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        phase = .finalizing
        overlayPanel?.close()
        environmentMonitor.stop()

        do {
            try store.update(&handle) { manifest in manifest.state = .finalizing }
            currentHandle = handle
            let result = try await recorder.stop()
            await realtimeClient?.finish()
            realtimeClient = nil
            camera.stop()
            try store.writeFrames(result.frames, to: handle)
            try store.update(&handle) { manifest in
                manifest.state = finalizationPlan.persistedState
                manifest.durationMs = result.durationMs
                manifest.artifacts.recording = CaptureArtifact(path: "recording.mp4")
                manifest.artifacts.microphone = CaptureArtifact(
                    path: "microphone.m4a",
                    startOffsetMs: result.trackStartOffsets.microphoneMs ?? 0
                )
                manifest.errorMessage = nil
            }
            currentHandle = handle
            try? store.markCleanShutdown(handle)
            recordingPlayer = AVPlayer(url: handle.recordingURL)
            self.recorder = nil
            self.clock = nil
            microphoneLevel = 0
            overlayPanel = nil
            phase = .recorded
            isStopping = false
            showMainWindow()
            refreshSessionLibrary()

            if finalizationPlan.shouldProcessTaskSpec {
                phase = .processing
                do {
                    try await process(handle: handle)
                } catch {
                    preserveRecordingAfterProcessingFailure(error, handle: handle)
                }
            }
        } catch {
            realtimeClient?.cancel()
            realtimeClient = nil
            camera.stop()
            isStopping = false
            fail(error, handle: handle)
        }
    }

    func cancelRecording() async {
        guard isCapturing, !isStopping else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "이 녹화를 취소할까요?"
        alert.informativeText = "현재 녹화와 입력 기록을 세션 단위로 휴지통에 이동합니다."
        alert.addButton(withTitle: "녹화 삭제")
        alert.addButton(withTitle: "계속 녹화")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isStopping = true
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        await recorder?.cancel()
        realtimeClient?.cancel()
        realtimeClient = nil
        camera.stop()
        overlayPanel?.close()
        environmentMonitor.stop()
        if let handle = currentHandle { try? await store.recycle(handle) }
        recorder = nil
        clock = nil
        overlayPanel = nil
        currentHandle = nil
        microphoneLevel = 0
        recordingWarning = nil
        isStopping = false
        phase = .idle
        showMainWindow()
    }

    /// Called by the application delegate for menu Quit, Command-Q, logout,
    /// and update relaunch. A recording is finalized before termination; AI
    /// processing is optional and never delays Quit after media is safe.
    func prepareForTermination() async -> Bool {
        switch LocalRecordingPolicy.terminationAction(for: localRecordingLifecyclePhase) {
        case .terminateImmediately:
            return true

        case .awaitRecordingFinalization:
            for _ in 0..<300 where phase == .finalizing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if phase == .processing {
                worker.cancel()
                return true
            }
            return currentHandle.map {
                LocalRecordingPolicy.mediaIsSafeForTermination(sessionState: $0.manifest.state)
            } ?? false

        case .cancelTaskSpecProcessingAndTerminate:
            worker.cancel()
            return true

        case .requestRecordingFinalization:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "녹화를 저장하고 종료할까요?"
            alert.informativeText = "먼저 재생 가능한 영상으로 안전하게 저장합니다. TaskSpec은 다음 실행에서 만들 수 있습니다."
            alert.addButton(withTitle: "저장 후 종료")
            alert.addButton(withTitle: "계속 녹화")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            await stopRecording(processTaskSpec: false)
            return currentHandle.map {
                LocalRecordingPolicy.mediaIsSafeForTermination(sessionState: $0.manifest.state)
            } ?? false
        }
    }

    func retryProcessing() async {
        guard let handle = currentHandle else { return }
        guard hasAPIKey else {
            errorMessage = "TaskSpec을 만들려면 OpenAI API 키를 저장해 주세요. 녹화 원본은 이 Mac에 보존되어 있습니다."
            phase = .recorded
            return
        }
        phase = .processing
        errorMessage = nil
        do { try await process(handle: handle) }
        catch { preserveRecordingAfterProcessingFailure(error, handle: handle) }
    }

    func copyAgentTask() {
        let candidates = [
            lastExportDirectory?.appendingPathComponent("AGENT_TASK.md"),
            currentHandle?.directory.appendingPathComponent("AGENT_TASK.md"),
            lastExportDirectory?.appendingPathComponent("taskspec.md")
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let recordingURL = currentHandle?.recordingURL,
           FileManager.default.fileExists(atPath: recordingURL.path) {
            text += "\n\n## 원본 설명 영상 (ground truth)\n\n`\(recordingURL.path)`\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        progressStage = "Codex/Claude Code용 작업 지시를 복사했습니다."
    }

    func saveShareSettings() {
        let trimmedURL = shareServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = shareUploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme == "https" || url.host == "localhost" else {
            shareError = "HTTPS 공유 서버 주소를 입력해 주세요."
            return
        }
        guard !trimmedToken.isEmpty else {
            shareError = "Recorder 업로드 토큰을 입력해 주세요."
            return
        }
        do {
            try KeychainStore.saveShareToken(trimmedToken)
            shareServerURL = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            shareUploadToken = trimmedToken
            shareError = nil
            shareStatus = "공유 설정을 안전하게 저장했습니다."
        } catch {
            shareError = error.localizedDescription
        }
    }

    func shareCurrentRecording() {
        guard let currentHandle else { return }
        beginShareUpload(for: currentHandle, force: true)
        if currentHandle.manifest.state == .completed {
            finalizeShareMetadata(for: currentHandle)
        }
    }

    func copyShareLink() {
        guard let shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
        shareStatus = "공유 링크를 복사했습니다."
    }

    func openShareLink() {
        guard let shareURL else { return }
        NSWorkspace.shared.open(shareURL)
    }

    func revealLastExport() {
        guard let lastExportDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportDirectory])
    }

    func revealSession() {
        guard let currentHandle else { return }
        store.reveal(currentHandle)
    }

    func refreshSessionLibrary() {
        let handles = (try? store.allSessions()) ?? []
        libraryHandles = Dictionary(uniqueKeysWithValues: handles.map { ($0.manifest.sessionId, $0) })
        sessionLibrary = handles.map { handle in
            SessionLibraryItem(
                id: handle.manifest.sessionId,
                createdAt: handle.manifest.createdAt,
                state: handle.manifest.state,
                durationMs: handle.manifest.durationMs,
                captureLabel: handle.manifest.captureLabel ?? handle.manifest.captureMode ?? "화면 녹화",
                projectName: handle.manifest.project.name,
                recovered: handle.manifest.recoveredAt != nil,
                hasRecording: FileManager.default.fileExists(atPath: handle.recordingURL.path)
            )
        }
    }

    func openLibrarySession(id: String) {
        refreshSessionLibrary()
        guard let handle = libraryHandles[id] else { return }
        currentHandle = handle
        shareURL = nil
        shareProgress = 0
        shareStatus = ""
        shareError = nil
        recordingPlayer = FileManager.default.fileExists(atPath: handle.recordingURL.path)
            ? AVPlayer(url: handle.recordingURL)
            : nil
        lastTaskSpec = try? store.loadTaskSpec(from: handle)
        if handle.manifest.state == .completed, lastTaskSpec != nil {
            errorMessage = nil
            phase = .complete
        } else if FileManager.default.fileExists(atPath: handle.recordingURL.path) {
            errorMessage = handle.manifest.errorMessage
            phase = .recorded
        } else {
            errorMessage = handle.manifest.errorMessage ?? "보존된 세션을 다시 처리할 수 있습니다."
            phase = .failed
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let url = await self.shareUploader.existingShareURL(sessionDirectory: handle.directory) {
                self.shareURL = url
                self.shareStatus = await self.shareUploader.needsResume(sessionDirectory: handle.directory)
                    ? "중단된 업로드를 다시 시작할 수 있습니다."
                    : "공유 페이지 준비 완료"
            }
        }
        showMainWindow()
    }

    func reprocessLibrarySession(id: String) async {
        openLibrarySession(id: id)
        guard canRetryProcessing else { return }
        await retryProcessing()
        refreshSessionLibrary()
    }

    func deleteLibrarySession(id: String) async {
        refreshSessionLibrary()
        guard let handle = libraryHandles[id], handle.manifest.sessionId != currentHandle?.manifest.sessionId else { return }
        try? await store.recycle(handle)
        refreshSessionLibrary()
    }

    func exportDiagnosticBundle() {
        guard diagnosticsConsent else {
            errorMessage = "먼저 진단 로그 저장에 동의해 주세요. 영상·음성·자막·키 입력은 포함되지 않습니다."
            return
        }
        let panel = NSSavePanel()
        panel.title = "SOOM 진단 패키지 저장"
        panel.nameFieldStringValue = "SOOM-Support-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagnosticsReporter().exportSupportBundle(sessions: (try? store.allSessions()) ?? [], to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func seekToEvidence(milliseconds: Int) {
        guard let recordingPlayer else { return }
        recordingPlayer.seek(
            to: CMTime(value: CMTimeValue(milliseconds), timescale: 1_000),
            toleranceBefore: CMTime(value: 100, timescale: 1_000),
            toleranceAfter: CMTime(value: 100, timescale: 1_000)
        )
        recordingPlayer.play()
    }

    func recordAgain() {
        if let currentHandle,
           currentHandle.manifest.state == .failed || currentHandle.manifest.state == .processing {
            UserDefaults.standard.set(currentHandle.manifest.sessionId, forKey: "dismissedRecoverySessionId")
        }
        currentHandle = nil
        lastTaskSpec = nil
        lastExportDirectory = nil
        lastScreenshotURL = nil
        liveTranscript = ""
        realtimeState = .disabled
        microphoneLevel = 0
        recordingWarning = nil
        recordingPlayer?.pause()
        recordingPlayer = nil
        progressStage = ""
        progressFraction = 0
        shareURL = nil
        shareProgress = 0
        shareStatus = ""
        shareError = nil
        errorMessage = nil
        phase = .idle
        Task { @MainActor [weak self] in await self?.updateCameraPreview() }
    }

    func showMainWindow() {
        if mainWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "SOOM"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(
                rootView: MainView(model: self).preferredColorScheme(.light)
            )
            window.center()
            mainWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func process(handle: SessionHandle) async throws {
        try await validateSessionMedia(handle)
        progressStage = "음성을 받아쓰는 중"
        progressFraction = 0.08
        let completed = try await worker.processSession(
            session: handle.directory,
            exportDirectory: exportDirectory,
            apiKey: apiKey,
            onProgress: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    self.progressStage = self.koreanStage(event.stage, fallback: event.message)
                    self.progressFraction = event.fraction ?? self.progressFraction
                }
            }
        )

        var updated = handle
        try store.update(&updated) { manifest in
            manifest.state = .completed
            manifest.artifacts.transcript = CaptureArtifact(path: "transcript.json")
            manifest.artifacts.taskSpec = CaptureArtifact(path: "taskspec.json")
            manifest.errorMessage = nil
        }
        currentHandle = updated
        lastTaskSpec = try store.loadTaskSpec(from: updated)
        if let export = completed.exportPath {
            lastExportDirectory = URL(fileURLWithPath: export, isDirectory: true)
        }
        if completed.exportStatus == "failed" {
            errorMessage = "TaskSpec은 세션에 안전하게 저장했지만 내보내기 폴더에 복사하지 못했습니다. 폴더 권한이나 저장 공간을 확인한 뒤 다시 생성해 주세요."
            progressStage = "TaskSpec은 로컬 세션에 저장되었습니다."
        } else {
            errorMessage = nil
            progressStage = "한국어 TaskSpec과 Agent 작업 파일을 만들었습니다."
        }
        progressFraction = 1
        phase = .complete
        refreshSessionLibrary()
        showMainWindow()
        if Self.hostedShareEnabled { finalizeShareMetadata(for: updated) }
    }

    private var shareConfiguration: ShareUploadConfiguration? {
        let trimmedURL = shareServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = shareUploadToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme == "https" || url.host == "localhost",
              !trimmedToken.isEmpty else { return nil }
        if sharePrivacy == .password, sharePassword.count < 4 { return nil }
        return ShareUploadConfiguration(
            baseURL: url,
            token: trimmedToken,
            privacy: sharePrivacy,
            password: sharePrivacy == .password ? sharePassword : nil,
            expirationDays: shareExpirationDays > 0 ? shareExpirationDays : nil,
            allowDownload: shareAllowDownload
        )
    }

    private func beginShareUpload(for handle: SessionHandle, force: Bool = false) {
        guard Self.hostedShareEnabled else { return }
        guard force || deliveryMode == .share else { return }
        let sessionID = handle.manifest.sessionId
        guard shareMediaTasks[sessionID] == nil || force else { return }
        guard let configuration = shareConfiguration else {
            shareError = "공유 설정에서 HTTPS 서버 주소와 업로드 토큰을 저장해 주세요."
            shareStatus = "로컬 원본은 안전하게 보존되었습니다."
            return
        }
        shareError = nil
        shareStatus = "비공개 공유 링크를 만드는 중"
        shareProgress = 0
        if force { shareMediaTasks[sessionID]?.cancel() }
        let uploader = shareUploader
        let createdHandler: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor in
                guard self?.currentHandle?.manifest.sessionId == sessionID else { return }
                self?.shareURL = url
                self?.shareStatus = "링크 준비 완료 · 영상을 업로드하는 중"
            }
        }
        let progressHandler: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard self?.currentHandle?.manifest.sessionId == sessionID else { return }
                self?.shareProgress = fraction
                self?.shareStatus = fraction >= 1 ? "영상 처리 대기 중" : "영상 업로드 \(Int(fraction * 100))%"
            }
        }
        shareMediaTasks[sessionID] = Task {
            try await uploader.uploadMedia(
                sessionDirectory: handle.directory,
                sessionID: handle.manifest.sessionId,
                title: handle.manifest.project.name ?? handle.manifest.captureLabel ?? "SOOM 녹화",
                recordingURL: handle.recordingURL,
                configuration: configuration,
                onCreated: createdHandler,
                onProgress: progressHandler
            )
        }
    }

    private func finalizeShareMetadata(for handle: SessionHandle) {
        guard Self.hostedShareEnabled else { return }
        let sessionID = handle.manifest.sessionId
        guard let mediaTask = shareMediaTasks[sessionID], let configuration = shareConfiguration else { return }
        let uploader = shareUploader
        Task { @MainActor [weak self] in
            defer { self?.shareMediaTasks[sessionID] = nil }
            do {
                let receipt = try await mediaTask.value
                if self?.currentHandle?.manifest.sessionId == sessionID {
                    self?.shareURL = receipt.shareURL
                    self?.shareStatus = "TaskSpec과 자막을 연결하는 중"
                }
                try await uploader.uploadMetadata(
                    sessionDirectory: handle.directory,
                    receipt: receipt,
                    configuration: configuration,
                    durationMs: handle.manifest.durationMs
                )
                if self?.currentHandle?.manifest.sessionId == sessionID {
                    self?.shareProgress = 1
                    self?.shareStatus = "공유 페이지 준비 완료"
                    self?.shareError = nil
                }
            } catch is CancellationError {
                return
            } catch {
                if self?.currentHandle?.manifest.sessionId == sessionID {
                    self?.shareError = error.localizedDescription
                    self?.shareStatus = "로컬 원본은 보존되었습니다. 다시 공유할 수 있습니다."
                }
            }
        }
    }

    private func resumePendingShareUploadsAtLaunch() async {
        guard shareConfiguration != nil else { return }
        let handles = (try? store.allSessions()) ?? []
        for handle in handles where await shareUploader.needsResume(sessionDirectory: handle.directory) {
            beginShareUpload(for: handle, force: true)
            if handle.manifest.state == .completed {
                finalizeShareMetadata(for: handle)
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let clock = self.clock else { return }
                let elapsed = clock.activeMilliseconds()
                self.overlayPanel?.state.elapsedMs = elapsed
                if elapsed - self.lastHealthCheckpointMs >= 1_000 {
                    self.lastHealthCheckpointMs = elapsed
                    self.checkpointRecordingHealth()
                }
                if elapsed >= self.maximumDurationMs, self.isCapturing {
                    await self.stopRecording()
                }
            }
        }
    }

    private func showOverlayPanel(for display: DisplayDescriptor) {
        let panel = RecordingPanelController(
            cameraSession: camera.session,
            cameraEnabled: cameraEnabled,
            display: display,
            onStop: { [weak self] in Task { @MainActor in await self?.stopRecording() } },
            onPause: { [weak self] in self?.togglePause() },
            onCancel: { [weak self] in Task { @MainActor in await self?.cancelRecording() } }
        )
        panel.state.realtimeState = realtimeState
        panel.state.liveCaption = liveTranscript
        panel.state.microphoneLevel = microphoneLevel
        panel.state.healthWarning = recordingWarning
        panel.onOverlayChanged = { [weak self] rect in
            self?.recorder?.setOverlayRect(rect)
            if var handle = self?.currentHandle {
                try? self?.store.update(&handle) { manifest in
                    manifest.cameraOverlayNormalizedTopLeft = rect
                }
                self?.currentHandle = handle
            }
        }
        overlayPanel = panel
        panel.show()
    }

    private func handleHotKey() {
        if isCapturing {
            Task { await stopRecording() }
        } else if startButtonEnabled {
            Task { await startRecording() }
        }
    }

    private func captureStoppedUnexpectedly(_ error: Error) async {
        guard !isStopping else { return }
        isStopping = true
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        overlayPanel?.close()
        environmentMonitor.stop()
        realtimeClient?.cancel()
        realtimeClient = nil
        camera.stop()
        if let recorder, var handle = currentHandle {
            do {
                try store.update(&handle) { manifest in manifest.state = .finalizing }
                let result = try await recorder.stop()
                try store.writeFrames(result.frames, to: handle)
                try store.update(&handle) { manifest in
                    manifest.state = .recorded
                    manifest.durationMs = result.durationMs
                    manifest.artifacts.recording = CaptureArtifact(path: "recording.mp4")
                    manifest.artifacts.microphone = CaptureArtifact(
                        path: "microphone.m4a",
                        startOffsetMs: result.trackStartOffsets.microphoneMs ?? 0
                    )
                    manifest.errorMessage = "캡처 입력이 중단됐지만 녹화 파일은 안전하게 저장했습니다: \(error.localizedDescription)"
                }
                try? store.markCleanShutdown(handle)
                currentHandle = handle
                recordingPlayer = AVPlayer(url: handle.recordingURL)
                self.recorder = nil
                clock = nil
                overlayPanel = nil
                microphoneLevel = 0
                isStopping = false
                errorMessage = handle.manifest.errorMessage
                phase = .recorded
                refreshSessionLibrary()
                showMainWindow()
                return
            } catch {
                await recorder.cancel()
            }
        }
        recorder = nil
        clock = nil
        overlayPanel = nil
        microphoneLevel = 0
        isStopping = false
        fail(error)
    }

    private func updateRealtimeState(_ state: RealtimeTranscriptionState) {
        realtimeState = state
        overlayPanel?.state.realtimeState = state
    }

    private func updateLiveCaption(_ caption: String) {
        liveTranscript = caption
        overlayPanel?.state.liveCaption = caption
    }

    private func updateMicrophoneLevel(_ level: Double) {
        microphoneLevel = level
        overlayPanel?.state.microphoneLevel = level
    }

    private func checkpointRecordingHealth() {
        guard let recorder, let handle = currentHandle else { return }
        let snapshot = recorder.healthSnapshot(
            availableDiskBytes: availableDiskBytes(at: handle.directory) ?? -1,
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState)
        )
        try? store.checkpoint(snapshot, for: handle)
        if diagnosticsConsent {
            store.appendDiagnostic(
                [
                    "at": snapshot.capturedAt,
                    "stage": "recording-health",
                    "durationMs": String(snapshot.durationMs),
                    "videoFrames": String(snapshot.videoFrames),
                    "droppedVideoFrames": String(snapshot.droppedVideoFrames),
                    "warnings": snapshot.warnings.map(\.rawValue).joined(separator: ",")
                ],
                to: handle
            )
        }
        recordingWarning = userFacingWarning(snapshot.warnings.first)
        overlayPanel?.state.healthWarning = recordingWarning
        if snapshot.warnings.contains(.criticalDiskSpace), isCapturing, !isStopping {
            Task { @MainActor [weak self] in await self?.stopRecording() }
        }
    }

    private func handleCaptureEnvironmentEvent(_ event: CaptureEnvironmentEvent) {
        switch event {
        case .cameraDisconnected:
            recordingWarning = userFacingWarning(.cameraDisconnected)
            overlayPanel?.state.healthWarning = recordingWarning
        case .cameraConnected:
            guard cameraEnabled, isCapturing else { return }
            Task { @MainActor [weak self] in
                do {
                    try await self?.camera.reconnect()
                    self?.recordingWarning = nil
                    self?.overlayPanel?.state.healthWarning = nil
                } catch {
                    self?.recordingWarning = error.localizedDescription
                }
            }
        case .microphoneDisconnected:
            recordingWarning = userFacingWarning(.microphoneDisconnected)
            overlayPanel?.state.healthWarning = recordingWarning
            Task { @MainActor [weak self] in await self?.stopRecording() }
        case .displayConfigurationChanged:
            recordingWarning = userFacingWarning(.displayConfigurationChanged)
            overlayPanel?.state.healthWarning = recordingWarning
        case .displayDisconnected:
            recordingWarning = userFacingWarning(.displayDisconnected)
            overlayPanel?.state.healthWarning = recordingWarning
            Task { @MainActor [weak self] in await self?.stopRecording() }
        case .systemWillSleep:
            recordingWarning = userFacingWarning(.systemWillSleep)
            overlayPanel?.state.healthWarning = recordingWarning
            Task { @MainActor [weak self] in await self?.stopRecording() }
        case .systemDidWake:
            break
        }
    }

    private func availableDiskBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        return try? url.resourceValues(forKeys: keys).volumeAvailableCapacityForImportantUsage
    }

    func resolveRecordingPreflightIssue() {
        let destination = MicrophoneDeviceState.defaultInputIsMuted() == true
            ? "x-apple.systempreferences:com.apple.Sound-Settings.extension"
            : "x-apple.systempreferences:com.apple.settings.Storage"
        guard let url = URL(string: destination) else { return }
        NSWorkspace.shared.open(url)
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func userFacingWarning(_ warning: RecordingWarningCode?) -> String? {
        switch warning {
        case .lowDiskSpace: return "저장 공간이 5GB 미만입니다."
        case .criticalDiskSpace: return "저장 공간 부족으로 안전하게 종료합니다."
        case .thermalPressure: return "Mac 온도가 높아 프레임이 낮아질 수 있습니다."
        case .writerBackpressure: return "영상 저장이 지연되고 있습니다."
        case .screenFramesMissing: return "화면 입력이 일시적으로 중단됐습니다."
        case .microphoneFramesMissing: return "마이크 입력이 일시적으로 중단됐습니다."
        case .avSyncDrift: return "화면과 마이크 시간차가 100ms를 넘었습니다."
        case .cameraDisconnected: return "카메라 연결이 끊겼습니다. 화면 녹화는 계속됩니다."
        case .microphoneDisconnected: return "마이크 연결이 끊겨 녹화를 종료합니다."
        case .displayDisconnected: return "녹화 중인 화면 연결이 끊겨 안전하게 종료합니다."
        case .displayConfigurationChanged: return "화면 구성이 변경됐습니다."
        case .systemWillSleep: return "Mac이 잠자기 상태로 들어가 녹화를 저장합니다."
        case nil: return nil
        }
    }

    private func updateCameraPreview() async {
        guard cameraEnabled,
              permissions.camera == .granted,
              ![.finalizing, .processing, .recorded, .complete, .failed].contains(phase) else {
            if !isCapturing { camera.stop() }
            return
        }
        do {
            try await camera.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fail(_ error: Error) {
        fail(error, handle: currentHandle)
    }

    private func preserveRecordingAfterProcessingFailure(_ error: Error, handle: SessionHandle) {
        var preserved = handle
        try? store.update(&preserved) { manifest in
            manifest.state = .recorded
            manifest.errorMessage = "TaskSpec 생성 실패: \(error.localizedDescription)"
        }
        currentHandle = preserved
        errorMessage = "TaskSpec을 만들지 못했습니다. 녹화 원본은 보존되었으며 다시 시도할 수 있습니다. \(error.localizedDescription)"
        progressStage = ""
        progressFraction = 0
        phase = .recorded
        refreshSessionLibrary()
        showMainWindow()
    }

    private func fail(_ error: Error, handle: SessionHandle?) {
        if var session = handle ?? currentHandle {
            try? store.update(&session) { manifest in
                manifest.state = .failed
                manifest.errorMessage = error.localizedDescription
            }
            currentHandle = session
        }
        errorMessage = error.localizedDescription
        progressStage = ""
        phase = .failed
        showMainWindow()
    }

    private func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func defaultOverlay(for display: DisplayDescriptor) -> RectValue {
        let width = 0.20
        let height = min(0.34, width * display.capturePixels.width / display.capturePixels.height)
        return RectValue(x: 0.035, y: max(0.035, 0.96 - height), width: width, height: height)
    }

    private func persistentSafetyIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: "safetyIdentifier") { return existing }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: "safetyIdentifier")
        return value
    }

    private func hideMainWindow() {
        mainWindowController?.window?.orderOut(nil)
    }

    private func applyReadyPhase() {
        if let currentHandle,
           currentHandle.manifest.state == .completed,
           (try? store.loadTaskSpec(from: currentHandle)) != nil {
            phase = .complete
        } else if let currentHandle,
                  currentHandle.manifest.state == .recorded ||
                    ((currentHandle.manifest.state == .failed || currentHandle.manifest.state == .processing) &&
                     sessionArtifactsLookComplete(currentHandle)) {
            errorMessage = currentHandle.manifest.errorMessage.map { userFacingRecoveryMessage($0) }
            phase = .recorded
        } else if let currentHandle,
                  currentHandle.manifest.state == .failed || currentHandle.manifest.state == .processing {
            errorMessage = SessionMediaValidationError.incompleteRecording.localizedDescription
            phase = .failed
        } else if permissions.canRecord(cameraEnabled: cameraEnabled || isCameraOnly) {
            phase = .idle
            Task { @MainActor [weak self] in await self?.updateCameraPreview() }
        } else {
            phase = .setup
        }
    }

    private func recoverInterruptedSessionsAtLaunch() async {
        let recovered = await SessionRecoveryManager(store: store).recoverInterruptedSessions()
        guard !recovered.isEmpty else { return }
        refreshSessionLibrary()
        let handle = recovered[0]
        currentHandle = handle
        recordingPlayer = AVPlayer(url: handle.recordingURL)
        recoveryNotice = "비정상 종료된 녹화 \(recovered.count)개를 복구했습니다."
        errorMessage = "녹화 파일을 복구했습니다. TaskSpec 생성을 다시 시도해 주세요."
        phase = .recorded
        showMainWindow()
    }

    private func userFacingRecoveryMessage(_ stored: String?) -> String {
        guard let stored else { return "이전 TaskSpec 처리를 다시 시도할 수 있습니다." }
        if stored.localizedCaseInsensitiveContains("schema") || stored.contains("스키마") {
            return "이전 AI 응답을 TaskSpec으로 저장하지 못했습니다. 수정된 worker로 다시 시도할 수 있습니다."
        }
        if let marker = stored.range(of: "{\"stage\":\"processing\"") {
            let tail = stored[marker.lowerBound...]
            if tail.contains("OpenAI API 키") { return "OpenAI API 키 또는 권한을 확인해 주세요." }
        }
        return "이전 TaskSpec 처리를 다시 시도할 수 있습니다. 원본 세션은 보존되어 있습니다."
    }

    private func koreanStage(_ stage: String?, fallback: String?) -> String {
        switch stage {
        case "transcription": return "한국어 음성을 받아쓰는 중"
        case "timeline": return "클릭과 화면을 정렬하는 중"
        case "understanding": return "웹 UI 수정사항을 구조화하는 중"
        case "export": return "TaskSpec과 Agent 작업 파일을 내보내는 중"
        default: return fallback ?? "AI 처리 중"
        }
    }

    private func sessionArtifactsLookComplete(_ handle: SessionHandle) -> Bool {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: handle.microphoneURL.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.int64Value >= 1_024,
              manager.fileExists(atPath: handle.frameIndexURL.path) else { return false }
        return true
    }

    private func validateSessionMedia(_ handle: SessionHandle) async throws {
        guard sessionArtifactsLookComplete(handle) else {
            throw SessionMediaValidationError.incompleteRecording
        }
        let asset = AVURLAsset(url: handle.microphoneURL)
        do {
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard playable, duration.isValid, duration.seconds.isFinite,
                  duration.seconds > 0, !audioTracks.isEmpty else {
                throw SessionMediaValidationError.incompleteRecording
            }
        } catch is SessionMediaValidationError {
            throw SessionMediaValidationError.incompleteRecording
        } catch {
            throw SessionMediaValidationError.incompleteRecording
        }
    }
}

private enum SessionMediaValidationError: LocalizedError {
    case incompleteRecording

    var errorDescription: String? {
        "녹화 도중 앱이 종료되어 미디어 파일이 완성되지 않았습니다. 이 세션은 다시 처리할 수 없으므로 새 녹화를 시작해 주세요."
    }
}
