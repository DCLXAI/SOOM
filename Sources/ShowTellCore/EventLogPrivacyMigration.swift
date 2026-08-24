import Foundation

public struct EventLogPrivacyMigrationResult: Sendable {
    public let data: Data
    public let migratedEvents: Int
    public let droppedMalformedLines: Int
}

/// One-way migration for sessions produced before SOOM stopped persisting
/// printable keyboard content. Malformed event lines are dropped rather than
/// retained because an undecodable record cannot be proven free of secrets.
public enum EventLogPrivacyMigration {
    public static func migrate(_ source: Data) -> EventLogPrivacyMigrationResult {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = String(decoding: source, as: UTF8.self).split(whereSeparator: \.isNewline)
        var output = Data()
        var migratedEvents = 0
        var droppedMalformedLines = 0

        for line in lines where !String(line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard var event = try? decoder.decode(InputEvent.self, from: Data(line.utf8)) else {
                droppedMalformedLines += 1
                continue
            }
            event = InputEventPrivacy.redactedForLocalStorage(event)
            event.context.windowTitle = nil
            guard let encoded = try? encoder.encode(event) else {
                droppedMalformedLines += 1
                continue
            }
            output.append(encoded)
            output.append(0x0A)
            migratedEvents += 1
        }

        return EventLogPrivacyMigrationResult(
            data: output,
            migratedEvents: migratedEvents,
            droppedMalformedLines: droppedMalformedLines
        )
    }
}
