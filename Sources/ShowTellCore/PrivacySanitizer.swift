import Foundation

private let safeControlKeyNames: [Int: String] = [
    36: "return", 48: "tab", 51: "delete", 53: "escape",
    115: "home", 116: "pageUp", 117: "forwardDelete", 119: "end",
    121: "pageDown", 123: "leftArrow", 124: "rightArrow", 125: "downArrow", 126: "upArrow"
]

/// Enforces the local event-log privacy contract before an input event leaves
/// the capture callback. Printable characters and their reversible virtual key
/// codes never reach events.ndjson. Only explicitly safe shortcuts and
/// non-text control keys retain a normalized label.
public enum InputEventPrivacy {
    public static func redactedForLocalStorage(_ event: InputEvent) -> InputEvent {
        var redacted = event
        redacted.characters = nil
        redacted.shortcut = nil

        guard event.kind == .keyDown else {
            if event.kind == .keyUp || event.kind == .modifiersChanged {
                redacted.keyCode = nil
            }
            return redacted
        }

        // Option-only key combinations can produce text (for example accents),
        // so only Command and Control establish a safe shortcut boundary.
        let modifiers = event.modifiers
        let modifierSet = Set(modifiers)
        let hasSafeShortcutModifier = !modifierSet.intersection(["command", "control"]).isEmpty
        let controlKey = event.keyCode.flatMap { safeControlKeyNames[$0] }

        if hasSafeShortcutModifier {
            let key = controlKey ?? safeASCIIShortcutKey(event.characters)
            redacted.shortcut = (modifiers + [key]).joined(separator: "+")
            redacted.keyCode = nil
        } else if let controlKey {
            redacted.shortcut = (modifiers + [controlKey]).joined(separator: "+")
            redacted.keyCode = nil
        } else {
            // A printable virtual key code is reversible even without its
            // Unicode representation, so it is content and must be removed.
            redacted.keyCode = nil
        }
        return redacted
    }

    private static func safeASCIIShortcutKey(_ characters: String?) -> String {
        guard let characters, characters.utf8.count == 1,
              let byte = characters.utf8.first,
              (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) else {
            return "key"
        }
        return characters.lowercased()
    }
}

public enum SanitizedTimelineKind: String, Codable, Sendable {
    case pointer
    case scroll
    case shortcut
    case typingActivity
    case captureGap
}

public struct SanitizedTimelineEvent: Codable, Equatable, Sendable {
    public var kind: SanitizedTimelineKind
    public var startMs: Int
    public var endMs: Int
    public var keyCount: Int?
    public var shortcut: String?
    public var pointerKind: String?
    public var position: PointValue?
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?
    public var context: ActiveContext
    public var reason: String?
}

public enum PrivacySanitizer {
    public static func sanitize(_ events: [InputEvent], typingIdleMs: Int = 700) -> [SanitizedTimelineEvent] {
        var output: [SanitizedTimelineEvent] = []
        var typingStart: InputEvent?
        var typingEnd: InputEvent?
        var typingCount = 0

        func flushTyping() {
            guard let start = typingStart, let end = typingEnd else { return }
            output.append(
                SanitizedTimelineEvent(
                    kind: .typingActivity,
                    startMs: start.tMs,
                    endMs: end.tMs,
                    keyCount: typingCount,
                    shortcut: nil,
                    pointerKind: nil,
                    position: nil,
                    scrollDeltaX: nil,
                    scrollDeltaY: nil,
                    context: start.context,
                    reason: nil
                )
            )
            typingStart = nil
            typingEnd = nil
            typingCount = 0
        }

        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            if let end = typingEnd, event.tMs - end.tMs > typingIdleMs {
                flushTyping()
            }

            switch event.kind {
            case .keyDown:
                let modifierSet = Set(event.modifiers)
                let isShortcut = !modifierSet.intersection(["command", "control"]).isEmpty
                let legacyControlKey = safeControlKeyNames[event.keyCode ?? -1]
                if let storedShortcut = event.shortcut {
                    flushTyping()
                    output.append(
                        SanitizedTimelineEvent(
                            kind: .shortcut,
                            startMs: event.tMs,
                            endMs: event.tMs,
                            keyCount: nil,
                            shortcut: storedShortcut,
                            pointerKind: nil,
                            position: nil,
                            scrollDeltaX: nil,
                            scrollDeltaY: nil,
                            context: event.context,
                            reason: nil
                        )
                    )
                } else if isShortcut || legacyControlKey != nil {
                    // Backward compatibility for sessions captured before
                    // shortcut labels were sanitized at the capture boundary.
                    flushTyping()
                    let keyName = legacyControlKey ?? safeShortcutKey(event.characters)
                    let pieces = event.modifiers + [keyName]
                    output.append(
                        SanitizedTimelineEvent(
                            kind: .shortcut,
                            startMs: event.tMs,
                            endMs: event.tMs,
                            keyCount: nil,
                            shortcut: pieces.joined(separator: "+"),
                            pointerKind: nil,
                            position: nil,
                            scrollDeltaX: nil,
                            scrollDeltaY: nil,
                            context: event.context,
                            reason: nil
                        )
                    )
                } else {
                    typingStart = typingStart ?? event
                    typingEnd = event
                    typingCount += 1
                }
            case .mouseDown, .mouseUp, .mouseDragged:
                flushTyping()
                output.append(
                    SanitizedTimelineEvent(
                        kind: .pointer,
                        startMs: event.tMs,
                        endMs: event.tMs,
                        keyCount: nil,
                        shortcut: nil,
                        pointerKind: event.kind.rawValue,
                        position: event.position?.displayNormalizedTopLeft,
                        scrollDeltaX: nil,
                        scrollDeltaY: nil,
                        context: event.context,
                        reason: nil
                    )
                )
            case .scroll:
                flushTyping()
                output.append(
                    SanitizedTimelineEvent(
                        kind: .scroll,
                        startMs: event.tMs,
                        endMs: event.tMs,
                        keyCount: nil,
                        shortcut: nil,
                        pointerKind: nil,
                        position: event.position?.displayNormalizedTopLeft,
                        scrollDeltaX: event.scrollDeltaX,
                        scrollDeltaY: event.scrollDeltaY,
                        context: event.context,
                        reason: nil
                    )
                )
            case .captureGap:
                flushTyping()
                output.append(
                    SanitizedTimelineEvent(
                        kind: .captureGap,
                        startMs: event.tMs,
                        endMs: event.tMs,
                        keyCount: nil,
                        shortcut: nil,
                        pointerKind: nil,
                        position: nil,
                        scrollDeltaX: nil,
                        scrollDeltaY: nil,
                        context: event.context,
                        reason: event.reason
                    )
                )
            case .keyUp, .modifiersChanged:
                break
            }
        }

        flushTyping()
        return output
    }

    private static func safeShortcutKey(_ characters: String?) -> String {
        guard let characters, characters.utf8.count == 1,
              let byte = characters.utf8.first,
              (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) else {
            return "key"
        }
        return characters.lowercased()
    }
}
