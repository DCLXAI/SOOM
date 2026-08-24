import AppKit
import Foundation
import ScreenCaptureKit
import ShowTellCore

enum CaptureMode: String, CaseIterable, Sendable {
    case display
    case window
    case region
    case cameraOnly

    var title: String {
        switch self {
        case .display: return "전체 화면"
        case .window: return "특정 윈도우"
        case .region: return "사용자 지정 영역"
        case .cameraOnly: return "카메라만"
        }
    }

    var icon: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .region: return "rectangle.dashed"
        case .cameraOnly: return "video.fill"
        }
    }
}

struct SelectedDisplaySource {
    let display: SCDisplay
    let filter: SCContentFilter
    let descriptor: DisplayDescriptor
    let mode: CaptureMode
    let label: String
    /// Region relative to the selected display in logical points. Nil captures
    /// the entire filter (full display or independent window).
    let sourceRect: CGRect?

    var capturesSystemAudio: Bool { mode != .cameraOnly }
    var tracksInputEvents: Bool { mode != .cameraOnly }
}

@MainActor
final class CaptureSourcePicker: NSObject, ObservableObject, SCContentSharingPickerObserver {
    @Published private(set) var selection: SelectedDisplaySource?
    @Published private(set) var errorMessage: String?

    private let picker = SCContentSharingPicker.shared
    private var requestedMode: CaptureMode = .display
    private var selectionContinuation: CheckedContinuation<SelectedDisplaySource?, Never>?
    private var regionSelector: RegionSelectionController?

    override init() {
        super.init()
        picker.add(self)
        picker.maximumStreamCount = 1
        picker.isActive = true
        configurePicker(modes: [.singleDisplay])
    }

    deinit { picker.remove(self) }

    func chooseDisplay() async -> SelectedDisplaySource? {
        await choose(mode: .display, pickerModes: [.singleDisplay], style: .display)
    }

    func chooseWindow() async -> SelectedDisplaySource? {
        await choose(mode: .window, pickerModes: [.singleWindow], style: .window)
    }

    func chooseScreenshotSource() async -> SelectedDisplaySource? {
        await choose(
            mode: .display,
            pickerModes: [.singleDisplay, .singleWindow],
            style: .none
        )
    }

    func chooseRegion() async -> SelectedDisplaySource? {
        guard selectionContinuation == nil else { return nil }
        do {
            let content = try await SCShareableContent.current
            let display = preferredDisplay(in: content)
            guard let display else { throw PickerError.noDisplay }
            guard let screen = screen(for: display.displayID) else { throw PickerError.noDisplay }

            return await withCheckedContinuation { continuation in
                let selector = RegionSelectionController(screen: screen) { [weak self] rect in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.regionSelector = nil
                    guard let rect else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let source = self.makeRegionSource(display: display, localTopLeftRect: rect, content: content)
                    self.selection = source
                    continuation.resume(returning: source)
                }
                regionSelector = selector
                selector.present()
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func selectCameraOnly() async -> SelectedDisplaySource? {
        do {
            let content = try await SCShareableContent.current
            guard let display = preferredDisplay(in: content) else { throw PickerError.noDisplay }
            let filter = cleanDisplayFilter(display: display, content: content)
            let descriptor = DisplayDescriptor(
                id: display.displayID,
                framePoints: rectValue(display.frame),
                capturePixels: SizeValue(width: 1280, height: 720),
                pointPixelScale: Double(filter.pointPixelScale)
            )
            let source = SelectedDisplaySource(
                display: display,
                filter: filter,
                descriptor: descriptor,
                mode: .cameraOnly,
                label: "카메라 영상 · 1280×720",
                sourceRect: nil
            )
            selection = source
            return source
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func restore(displayID: UInt32) async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            selection = makeDisplaySource(display: display, content: content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            selectionContinuation?.resume(returning: nil)
            selectionContinuation = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in await resolve(filter: filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            errorMessage = error.localizedDescription
            selectionContinuation?.resume(returning: nil)
            selectionContinuation = nil
        }
    }

    private func choose(
        mode: CaptureMode,
        pickerModes: SCContentSharingPickerMode,
        style: SCShareableContentStyle
    ) async -> SelectedDisplaySource? {
        guard selectionContinuation == nil else { return nil }
        requestedMode = mode
        configurePicker(modes: pickerModes)
        return await withCheckedContinuation { continuation in
            selectionContinuation = continuation
            if style == .none { picker.present() }
            else { picker.present(using: style) }
        }
    }

    private func configurePicker(modes: SCContentSharingPickerMode) {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = modes
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
    }

    private func resolve(filter: SCContentFilter) async {
        do {
            let content = try await SCShareableContent.current
            let info = SCShareableContent.info(for: filter)
            let mode: CaptureMode = filter.style == .window ? .window : requestedMode
            let display = displayForFilter(filter, contentRect: info.contentRect, content: content)
            guard let display else { throw PickerError.noDisplay }

            let source: SelectedDisplaySource
            if mode == .window {
                source = makeWindowSource(filter: filter, display: display, contentRect: info.contentRect)
            } else {
                source = makeDisplaySource(display: display, content: content)
            }
            selection = source
            selectionContinuation?.resume(returning: source)
            selectionContinuation = nil
        } catch {
            errorMessage = error.localizedDescription
            selectionContinuation?.resume(returning: nil)
            selectionContinuation = nil
        }
    }

    private func makeDisplaySource(display: SCDisplay, content: SCShareableContent) -> SelectedDisplaySource {
        let filter = cleanDisplayFilter(display: display, content: content)
        let descriptor = makeDescriptor(
            display: display,
            frame: display.frame,
            logicalSize: display.frame.size,
            scale: Double(filter.pointPixelScale)
        )
        return SelectedDisplaySource(
            display: display,
            filter: filter,
            descriptor: descriptor,
            mode: .display,
            label: "디스플레이 \(display.displayID) · \(pixelLabel(descriptor.capturePixels))",
            sourceRect: nil
        )
    }

    private func makeWindowSource(filter: SCContentFilter, display: SCDisplay, contentRect: CGRect) -> SelectedDisplaySource {
        let frame = contentRect.width > 1 && contentRect.height > 1 ? contentRect : filter.contentRect
        let descriptor = makeDescriptor(
            display: display,
            frame: frame,
            logicalSize: filter.contentRect.size,
            scale: Double(filter.pointPixelScale)
        )
        var label = "선택한 윈도우"
        if #available(macOS 15.2, *), let window = filter.includedWindows.first {
            let app = window.owningApplication?.applicationName
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            label = [app, title].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " · ")
        }
        return SelectedDisplaySource(
            display: display,
            filter: filter,
            descriptor: descriptor,
            mode: .window,
            label: "\(label) · \(pixelLabel(descriptor.capturePixels))",
            sourceRect: nil
        )
    }

    private func makeRegionSource(
        display: SCDisplay,
        localTopLeftRect: CGRect,
        content: SCShareableContent
    ) -> SelectedDisplaySource {
        let filter = cleanDisplayFilter(display: display, content: content)
        let globalFrame = CGRect(
            x: display.frame.minX + localTopLeftRect.minX,
            y: display.frame.minY + localTopLeftRect.minY,
            width: localTopLeftRect.width,
            height: localTopLeftRect.height
        )
        let descriptor = makeDescriptor(
            display: display,
            frame: globalFrame,
            logicalSize: localTopLeftRect.size,
            scale: Double(filter.pointPixelScale)
        )
        return SelectedDisplaySource(
            display: display,
            filter: filter,
            descriptor: descriptor,
            mode: .region,
            label: "\(Int(localTopLeftRect.width))×\(Int(localTopLeftRect.height)) pt · \(pixelLabel(descriptor.capturePixels))",
            sourceRect: localTopLeftRect
        )
    }

    private func makeDescriptor(
        display: SCDisplay,
        frame: CGRect,
        logicalSize: CGSize,
        scale: Double
    ) -> DisplayDescriptor {
        let rawWidth = max(2, logicalSize.width * scale)
        let rawHeight = max(2, logicalSize.height * scale)
        let resizeScale = min(1, 2560 / max(rawWidth, rawHeight))
        let width = max(2, (Int(rawWidth * resizeScale) / 2) * 2)
        let height = max(2, (Int(rawHeight * resizeScale) / 2) * 2)
        return DisplayDescriptor(
            id: display.displayID,
            framePoints: rectValue(frame),
            capturePixels: SizeValue(width: Double(width), height: Double(height)),
            pointPixelScale: scale
        )
    }

    private func cleanDisplayFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let ownBundleID = Bundle.main.bundleIdentifier
        let currentProcessID = getpid()
        let ownApps = content.applications.filter { application in
            application.processID == currentProcessID ||
                (ownBundleID != nil && application.bundleIdentifier == ownBundleID)
        }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    private func preferredDisplay(in content: SCShareableContent) -> SCDisplay? {
        if let selected = selection?.display { return selected }
        guard let screen = NSScreen.main,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            return content.displays.first
        }
        return content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
    }

    private func displayForFilter(_ filter: SCContentFilter, contentRect: CGRect, content: SCShareableContent) -> SCDisplay? {
        if #available(macOS 15.2, *), let included = filter.includedDisplays.first { return included }
        return content.displays.max { lhs, rhs in overlap(lhs.frame, contentRect) < overlap(rhs.frame, contentRect) }
    }

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func rectValue(_ rect: CGRect) -> RectValue {
        RectValue(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    private func pixelLabel(_ size: SizeValue) -> String { "\(Int(size.width))×\(Int(size.height))" }
    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat { lhs.intersection(rhs).width * lhs.intersection(rhs).height }
}

enum PickerError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "선택한 화면을 확인할 수 없습니다." }
}
