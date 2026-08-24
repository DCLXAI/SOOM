import Foundation
import Testing
@testable import ShowTellCore

@Suite struct PrivacySanitizerTests {
    @Test func printableCharactersBecomeCountOnly() throws {
        let secret = "hunter2"
        let events = secret.enumerated().map { index, character in
            InputEvent(
                sequence: index,
                tMs: index * 80,
                kind: .keyDown,
                keyCode: index,
                characters: String(character),
                context: ActiveContext(appName: "Browser")
            )
        }

        let sanitized = PrivacySanitizer.sanitize(events)
        let data = try JSONEncoder().encode(sanitized)
        let encoded = String(decoding: data, as: UTF8.self)

        #expect(sanitized.count == 1)
        #expect(sanitized.first?.kind == .typingActivity)
        #expect(sanitized.first?.keyCount == secret.count)
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains("characters"))
    }

    @Test func commandShortcutKeepsOnlySafeKey() {
        let event = InputEvent(
            sequence: 1,
            tMs: 100,
            kind: .keyDown,
            keyCode: 8,
            characters: "c",
            modifiers: ["command"]
        )

        #expect(PrivacySanitizer.sanitize([event]).first?.shortcut == "command+c")
    }

    @Test func captureBoundaryRemovesPrintableCharacterAndVirtualKeyCode() throws {
        let event = InputEventPrivacy.redactedForLocalStorage(
            InputEvent(
                sequence: 7,
                tMs: 320,
                kind: .keyDown,
                keyCode: 35,
                characters: "p",
                context: ActiveContext(appName: "Browser")
            )
        )

        #expect(event.characters == nil)
        #expect(event.keyCode == nil)
        #expect(event.shortcut == nil)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("characters"))
        #expect(!encoded.contains("keyCode"))
        #expect(PrivacySanitizer.sanitize([event]).first?.keyCount == 1)
        #expect(PrivacySanitizer.sanitize([event]).first?.startMs == 320)
    }

    @Test func captureBoundaryStoresOnlyNormalizedSafeShortcut() throws {
        let event = InputEventPrivacy.redactedForLocalStorage(
            InputEvent(
                sequence: 1,
                tMs: 100,
                kind: .keyDown,
                keyCode: 8,
                characters: "C",
                modifiers: ["command"]
            )
        )

        #expect(event.characters == nil)
        #expect(event.keyCode == nil)
        #expect(event.shortcut == "command+c")
        #expect(PrivacySanitizer.sanitize([event]).first?.shortcut == "command+c")
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("characters"))
        #expect(!encoded.contains("keyCode"))
        #expect(encoded.contains("command+c"))
    }

    @Test func optionModifiedTextRemainsCountOnly() {
        let event = InputEventPrivacy.redactedForLocalStorage(
            InputEvent(
                sequence: 1,
                tMs: 100,
                kind: .keyDown,
                keyCode: 14,
                characters: "é",
                modifiers: ["option"]
            )
        )

        #expect(event.shortcut == nil)
        #expect(event.characters == nil)
        #expect(event.keyCode == nil)
        #expect(PrivacySanitizer.sanitize([event]).first?.kind == .typingActivity)
    }

    @Test func manifestDeclaresCaptureBoundaryPrivacyContract() throws {
        let policy = PrivacyPolicy(safetyIdentifier: "test-user")
        #expect(!policy.recordsRawKeystrokesLocally)
        #expect(policy.recordsTypingActivityLocally)
        #expect(policy.recordsSafeShortcutsLocally)
        #expect(!policy.evidenceFramesIncludeCamera)
        #expect(!policy.uploadsRawKeystrokes)
        #expect(!policy.uploadsRecordingFile)

        let encoded = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
        #expect(encoded.contains("\"recordsRawKeystrokesLocally\":false"))
        #expect(encoded.contains("\"recordsTypingActivityLocally\":true"))
        #expect(encoded.contains("\"recordsSafeShortcutsLocally\":true"))
        #expect(encoded.contains("\"evidenceFramesIncludeCamera\":false"))
    }

    @Test func legacyEventLogMigrationErasesContentAndDropsUnverifiableLines() throws {
        let legacy = InputEvent(
            sequence: 1,
            tMs: 50,
            kind: .keyDown,
            keyCode: 35,
            characters: "password-canary",
            context: ActiveContext(
                appName: "Browser",
                bundleIdentifier: "example.browser",
                windowTitle: "Customer Secret Document"
            )
        )
        var source = try JSONEncoder().encode(legacy)
        source.append(0x0A)
        source.append(Data("{malformed-password-canary}\n".utf8))

        let migrated = EventLogPrivacyMigration.migrate(source)
        let text = String(decoding: migrated.data, as: UTF8.self)
        let firstLine = try #require(text.split(whereSeparator: \.isNewline).first)
        let decoded = try JSONDecoder().decode(InputEvent.self, from: Data(firstLine.utf8))

        #expect(migrated.migratedEvents == 1)
        #expect(migrated.droppedMalformedLines == 1)
        #expect(decoded.characters == nil)
        #expect(decoded.keyCode == nil)
        #expect(decoded.context.windowTitle == nil)
        #expect(!text.contains("password-canary"))
        #expect(!text.contains("Customer Secret Document"))
    }
}
