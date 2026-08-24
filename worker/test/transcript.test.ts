import { describe, expect, test } from "bun:test";
import { canonicalizeTranscript } from "../src/transcript";

describe("canonical transcript timeline", () => {
  test("converts Whisper seconds to session milliseconds with microphone offset", () => {
    const transcript = canonicalizeTranscript(
      { text: "여기", language: "ko", words: [{ word: "여기", start: 0.2, end: 0.45 }] },
      350,
      5_000,
    );
    expect(transcript.timeUnit).toBe("ms");
    expect(transcript.words).toEqual([{ word: "여기", startMs: 550, endMs: 800 }]);
    expect(JSON.stringify(transcript)).not.toContain('"start"');
  });

  test("rejects malformed or out-of-session word timestamps", () => {
    expect(() => canonicalizeTranscript(
      { text: "bad", language: "en", words: [{ word: "bad", start: 2, end: 1 }] }, 0, 5_000,
    )).toThrow("invalid timestamps");
    expect(() => canonicalizeTranscript(
      { text: "late", language: "en", words: [{ word: "late", start: 7, end: 8 }] }, 0, 5_000,
    )).toThrow("outside the session timeline");
  });
});
