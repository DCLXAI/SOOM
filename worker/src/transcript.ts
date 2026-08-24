import type { RawTranscriptDocument, TranscriptDocument } from "./types";

const MAX_TRANSCRIPT_TEXT_BYTES = 2 * 1024 * 1024;
const MAX_TRANSCRIPT_WORDS = 50_000;
const MAX_WORD_BYTES = 1_024;

export function canonicalizeTranscript(
  raw: RawTranscriptDocument,
  microphoneStartOffsetMs: number,
  durationMs: number,
): TranscriptDocument {
  if (new TextEncoder().encode(raw.text).byteLength > MAX_TRANSCRIPT_TEXT_BYTES) {
    throw new Error("Transcript text exceeds the 2 MB limit");
  }
  if (raw.words.length > MAX_TRANSCRIPT_WORDS) throw new Error("Transcript word count exceeds the limit");
  if (!Number.isInteger(microphoneStartOffsetMs) || microphoneStartOffsetMs < 0 || microphoneStartOffsetMs > durationMs) {
    throw new Error("Microphone start offset is outside the session timeline");
  }

  const words = raw.words.map((candidate, index) => {
    if (typeof candidate.word !== "string" || new TextEncoder().encode(candidate.word).byteLength > MAX_WORD_BYTES) {
      throw new Error(`Transcript word ${index} is invalid`);
    }
    if (!Number.isFinite(candidate.start) || !Number.isFinite(candidate.end)
      || candidate.start < 0 || candidate.end < candidate.start) {
      throw new Error(`Transcript word ${index} has invalid timestamps`);
    }
    const startMs = Math.round(candidate.start * 1_000) + microphoneStartOffsetMs;
    const endMs = Math.round(candidate.end * 1_000) + microphoneStartOffsetMs;
    if (startMs > durationMs + 1_000 || endMs > durationMs + 1_000) {
      throw new Error(`Transcript word ${index} falls outside the session timeline`);
    }
    return {
      word: candidate.word,
      startMs: Math.min(startMs, durationMs),
      endMs: Math.min(Math.max(endMs, startMs), durationMs),
    };
  }).sort((left, right) => left.startMs - right.startMs || left.endMs - right.endMs);

  return {
    text: raw.text,
    language: raw.language,
    timeUnit: "ms",
    words,
  };
}
