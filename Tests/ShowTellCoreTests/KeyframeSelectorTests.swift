import Testing
@testable import ShowTellCore

@Suite struct KeyframeSelectorTests {
    @Test func prioritizesBoundariesAndInteractionEvidence() {
        let candidates = [
            FrameCandidate(file: "periodic.jpg", tMs: 5_000, kind: .periodic),
            FrameCandidate(file: "click.jpg", tMs: 3_000, kind: .click),
            FrameCandidate(file: "first.jpg", tMs: 0, kind: .first),
            FrameCandidate(file: "last.jpg", tMs: 10_000, kind: .last)
        ]

        let selected = KeyframeSelector.select(candidates, limit: 3)

        #expect(Set(selected.map(\.file)) == Set(["first.jpg", "click.jpg", "last.jpg"]))
        #expect(selected.map(\.tMs) == [0, 3_000, 10_000])
    }
}
