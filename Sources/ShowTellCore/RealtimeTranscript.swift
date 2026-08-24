import Foundation

/// Keeps Realtime transcription deltas isolated by item so late events from a
/// previous speech turn cannot overwrite the currently visible caption.
public struct RealtimeTranscriptAccumulator: Equatable, Sendable {
    public private(set) var completed: [String] = []
    public private(set) var partials: [String: String] = [:]
    public private(set) var activeItemID: String?

    public init() {}

    public mutating func append(delta: String, itemID: String) {
        guard !delta.isEmpty else { return }
        partials[itemID, default: ""] += delta
        activeItemID = itemID
    }

    public mutating func complete(transcript: String, itemID: String) {
        partials.removeValue(forKey: itemID)
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { completed.append(cleaned) }
        if activeItemID == itemID { activeItemID = nil }
    }

    public var visibleCaption: String {
        if let activeItemID, let partial = partials[activeItemID], !partial.isEmpty {
            return partial.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return completed.last ?? ""
    }

    public var fullText: String {
        let finalText = completed.joined(separator: " ")
        guard let activeItemID, let partial = partials[activeItemID], !partial.isEmpty else {
            return finalText
        }
        return [finalText, partial]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
