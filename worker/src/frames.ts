import { isAbsolute, relative, resolve, sep } from "node:path";
import type { FrameCandidate } from "./types";

const weights: Record<FrameCandidate["kind"], number> = {
  first: 1_000,
  last: 990,
  click: 900,
  afterClick: 850,
  typingSettled: 700,
  scrollSettled: 650,
  periodic: 100,
};

export function selectFrames(candidates: FrameCandidate[], limit = 12, minimumSpacingMs = 650): FrameCandidate[] {
  if (limit <= 0) return [];
  const chosen: FrameCandidate[] = [];
  const ranked = [...candidates].sort((a, b) => weights[b.kind] - weights[a.kind] || a.tMs - b.tMs);
  for (const candidate of ranked) {
    const boundary = candidate.kind === "first" || candidate.kind === "last";
    const spaced = chosen.every((other) => Math.abs(other.tMs - candidate.tMs) >= minimumSpacingMs);
    if (boundary || spaced) chosen.push(candidate);
    if (chosen.length === limit) break;
  }
  if (chosen.length < Math.min(limit, candidates.length)) {
    for (const candidate of [...candidates].sort((a, b) => a.tMs - b.tMs)) {
      if (!chosen.includes(candidate)) chosen.push(candidate);
      if (chosen.length === limit) break;
    }
  }
  return chosen.sort((a, b) => a.tMs - b.tMs);
}

export function safeSessionPath(sessionPath: string, relativePath: string): string {
  if (isAbsolute(relativePath)) throw new Error("Session artifact path must be relative");
  const root = resolve(sessionPath);
  const target = resolve(root, relativePath);
  const relation = relative(root, target);
  if (relation.startsWith(`..${sep}`) || relation === ".." || isAbsolute(relation)) {
    throw new Error("Session artifact escapes the session directory");
  }
  return target;
}
