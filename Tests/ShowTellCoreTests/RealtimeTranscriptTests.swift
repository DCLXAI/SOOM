import Testing
@testable import ShowTellCore

@Suite("Realtime transcript accumulation")
struct RealtimeTranscriptTests {
    @Test("deltas accumulate within their own speech item")
    func accumulatesDeltas() {
        var transcript = RealtimeTranscriptAccumulator()
        transcript.append(delta: "여기 ", itemID: "item-1")
        transcript.append(delta: "버튼", itemID: "item-1")

        #expect(transcript.visibleCaption == "여기 버튼")
        #expect(transcript.fullText == "여기 버튼")
    }

    @Test("completed turns remain while a new partial arrives")
    func keepsCompletedTurns() {
        var transcript = RealtimeTranscriptAccumulator()
        transcript.append(delta: "첫 번째", itemID: "item-1")
        transcript.complete(transcript: "첫 번째 작업", itemID: "item-1")
        transcript.append(delta: "두 번째", itemID: "item-2")

        #expect(transcript.visibleCaption == "두 번째")
        #expect(transcript.fullText == "첫 번째 작업 두 번째")
    }

    @Test("late completion does not replace the active caption")
    func handlesOutOfOrderCompletion() {
        var transcript = RealtimeTranscriptAccumulator()
        transcript.append(delta: "이전", itemID: "item-1")
        transcript.append(delta: "현재 발화", itemID: "item-2")
        transcript.complete(transcript: "이전 발화", itemID: "item-1")

        #expect(transcript.visibleCaption == "현재 발화")
    }
}
