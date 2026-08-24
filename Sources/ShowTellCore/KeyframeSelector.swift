import Foundation

public enum KeyframeSelector {
    private static let weights: [FrameKind: Int] = [
        .first: 1_000,
        .last: 990,
        .click: 900,
        .afterClick: 850,
        .typingSettled: 700,
        .scrollSettled: 650,
        .periodic: 100
    ]

    public static func select(_ candidates: [FrameCandidate], limit: Int = 12, minimumSpacingMs: Int = 650) -> [FrameCandidate] {
        guard limit > 0 else { return [] }
        var chosen: [FrameCandidate] = []

        for candidate in candidates.sorted(by: rankedBefore) {
            let isBoundary = candidate.kind == .first || candidate.kind == .last
            let isFarEnough = chosen.allSatisfy { abs($0.tMs - candidate.tMs) >= minimumSpacingMs }
            if isBoundary || isFarEnough {
                chosen.append(candidate)
            }
            if chosen.count == limit { break }
        }

        if chosen.count < min(limit, candidates.count) {
            for candidate in candidates.sorted(by: { $0.tMs < $1.tMs }) where !chosen.contains(candidate) {
                chosen.append(candidate)
                if chosen.count == limit { break }
            }
        }

        return chosen.sorted(by: { $0.tMs < $1.tMs })
    }

    private static func rankedBefore(_ lhs: FrameCandidate, _ rhs: FrameCandidate) -> Bool {
        let left = weights[lhs.kind, default: 0]
        let right = weights[rhs.kind, default: 0]
        return left == right ? lhs.tMs < rhs.tMs : left > right
    }
}
