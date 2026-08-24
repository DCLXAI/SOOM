type TranscriptWord = { word: string; start: number; end: number };

function timestamp(seconds: number): string {
  const millis = Math.max(0, Math.round(seconds * 1_000));
  const hours = Math.floor(millis / 3_600_000);
  const minutes = Math.floor((millis % 3_600_000) / 60_000);
  const secs = Math.floor((millis % 60_000) / 1_000);
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}.${String(millis % 1_000).padStart(3, "0")}`;
}

export function transcriptWords(value: unknown): TranscriptWord[] {
  if (!value || typeof value !== "object" || !("words" in value) || !Array.isArray(value.words)) return [];
  return value.words.flatMap((candidate) => {
    if (!candidate || typeof candidate !== "object") return [];
    const record = candidate as Record<string, unknown>;
    const word = typeof record.word === "string" ? record.word.trim() : "";
    const start = Number(record.start);
    const end = Number(record.end);
    return word && Number.isFinite(start) && Number.isFinite(end) && end >= start ? [{ word, start, end }] : [];
  });
}

export function makeWebVtt(words: TranscriptWord[]): string {
  const cues = ["WEBVTT", ""];
  for (let index = 0; index < words.length; index += 8) {
    const group = words.slice(index, index + 8);
    if (!group.length) continue;
    cues.push(`${timestamp(group[0].start)} --> ${timestamp(group.at(-1)?.end ?? group[0].end)}`);
    cues.push(group.map((item) => item.word).join(" "));
    cues.push("");
  }
  return cues.join("\n");
}
