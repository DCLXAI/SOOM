import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ShowTellCore

final class InputEventMonitor: @unchecked Sendable {
    typealias EventHandler = @Sendable (InputEvent) -> Void
    typealias FrameRequest = @Sendable (FrameKind, Int, PointValue?) -> Void

    private let display: DisplayDescriptor
    private let clock: SessionClock
    private let onEvent: EventHandler
    private let onFrameRequest: FrameRequest
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // CGEventTap stores userInfo as an unmanaged pointer. Keep one explicit
    // retain alive until the tap is invalidated so a queued callback can never
    // dereference an already-deallocated monitor (and its SessionClock).
    private var retainedCallbackTarget: Unmanaged<InputEventMonitor>?
    private var secureInputTimer: Timer?
    private var sequence = 0
    private var paused = false
    private var secureGapOpen = false
    private var lastDragMs = -1_000

    init(
        display: DisplayDescriptor,
        clock: SessionClock,
        onEvent: @escaping EventHandler,
        onFrameRequest: @escaping FrameRequest
    ) {
        self.display = display
        self.clock = clock
        self.onEvent = onEvent
        self.onFrameRequest = onFrameRequest
    }

    @MainActor func start() throws {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
            .tapDisabledByTimeout, .tapDisabledByUserInput
        ]
        let mask = types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }
        let retainedTarget = Unmanaged.passRetained(self)
        let pointer = retainedTarget.toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<InputEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.receive(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: pointer
        ) else {
            retainedTarget.release()
            throw InputMonitorError.unavailable
        }
        retainedCallbackTarget = retainedTarget
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollSecureInput()
        }
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    @MainActor func stop() {
        secureInputTimer?.invalidate()
        secureInputTimer = nil
        if secureGapOpen {
            appendGap(reason: "secureInputEnded")
            secureGapOpen = false
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        let retainedTarget = retainedCallbackTarget
        retainedCallbackTarget = nil
        retainedTarget?.release()
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            appendGap(reason: type == .tapDisabledByTimeout ? "eventTapTimeout" : "eventTapDisabled")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        lock.lock()
        let shouldIgnore = paused
        lock.unlock()
        guard !shouldIgnore else { return }

        let tMs = clock.activeMilliseconds()
        if [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
            guard tMs - lastDragMs >= 50 else { return }
            lastDragMs = tMs
        }

        let kind: InputEventKind
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .mouseUp
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .mouseDragged
        case .scrollWheel: kind = .scroll
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .modifiersChanged
        default: return
        }

        let isPointer = [.mouseDown, .mouseUp, .mouseDragged, .scroll].contains(kind)
        let globalPoint = PointValue(x: event.location.x, y: event.location.y)
        // A global event tap can observe other displays and applications. Do
        // not turn an interaction outside the selected capture into a clamped
        // edge click inside the recording.
        guard !isPointer || CoordinateMapper.contains(globalTopLeft: globalPoint, display: display) else { return }
        let position = isPointer
            ? CoordinateMapper.map(
                globalTopLeft: globalPoint,
                display: display
            )
            : nil
        let context = activeContext()
        let input = InputEventPrivacy.redactedForLocalStorage(InputEvent(
            sequence: nextSequence(),
            tMs: tMs,
            kind: kind,
            position: position,
            mouseButton: isPointer ? buttonName(for: event) : nil,
            scrollDeltaX: kind == .scroll ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : nil,
            scrollDeltaY: kind == .scroll ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) : nil,
            keyCode: [.keyDown, .keyUp, .modifiersChanged].contains(kind) ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : nil,
            characters: kind == .keyDown ? unicodeCharacters(from: event) : nil,
            modifiers: modifierNames(event.flags),
            context: context
        ))
        onEvent(input)

        if kind == .mouseDown, let point = position?.displayNormalizedTopLeft {
            onFrameRequest(.click, tMs, point)
            onFrameRequest(.afterClick, tMs + 350, point)
        } else if kind == .scroll {
            onFrameRequest(.scrollSettled, tMs + 450, nil)
        } else if kind == .keyDown {
            onFrameRequest(.typingSettled, tMs + 700, nil)
        }
    }

    private func pollSecureInput() {
        let enabled = IsSecureEventInputEnabled()
        if enabled && !secureGapOpen {
            secureGapOpen = true
            appendGap(reason: "secureInputStarted")
        } else if !enabled && secureGapOpen {
            secureGapOpen = false
            appendGap(reason: "secureInputEnded")
        }
    }

    private func appendGap(reason: String) {
        onEvent(
            InputEvent(
                sequence: nextSequence(),
                tMs: clock.activeMilliseconds(),
                kind: .captureGap,
                context: activeContext(),
                reason: reason
            )
        )
    }

    private func nextSequence() -> Int {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        return sequence
    }

    private func buttonName(for event: CGEvent) -> String {
        switch event.getIntegerValueField(.mouseEventButtonNumber) {
        case 0: return "left"
        case 1: return "right"
        default: return "other"
        }
    }

    private func unicodeCharacters(from event: CGEvent) -> String? {
        var length = 0
        var characters = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    private func modifierNames(_ flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("command") }
        if flags.contains(.maskControl) { names.append("control") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskAlphaShift) { names.append("capsLock") }
        if flags.contains(.maskSecondaryFn) { names.append("fn") }
        return names
    }

    private func activeContext() -> ActiveContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ActiveContext() }
        return ActiveContext(
            appName: app.localizedName,
            bundleIdentifier: app.bundleIdentifier,
            windowTitle: nil
        )
    }
}

enum InputMonitorError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "입력 모니터링을 시작할 수 없습니다. 시스템 설정에서 입력 모니터링 권한을 확인해 주세요."
    }
}
