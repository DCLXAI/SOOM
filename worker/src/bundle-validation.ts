import Ajv, { type ValidateFunction } from "ajv";
import { open, lstat, realpath } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { FrameCandidate, InputEvent, SessionManifest } from "./types";

const MAX_MANIFEST_BYTES = 1 * 1024 * 1024;
const MAX_EVENTS_BYTES = 16 * 1024 * 1024;
const MAX_EVENT_LINE_BYTES = 16 * 1024;
const MAX_EVENTS = 50_000;
const MAX_FRAME_INDEX_BYTES = 512 * 1024;
const MAX_FRAME_CANDIDATES = 100;
const MAX_FRAME_BYTES = 20 * 1024 * 1024;
const MAX_JPEG_HEADER_BYTES = 1 * 1024 * 1024;
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
const MAX_DURATION_MS = 180_000;
const MAX_IMAGE_DIMENSION = 16_384;
const MAX_IMAGE_PIXELS = 80_000_000;

const pointSchema = {
  type: "object",
  additionalProperties: false,
  required: ["x", "y"],
  properties: { x: { type: "number" }, y: { type: "number" } },
} as const;

const artifactSchema = {
  type: "object",
  additionalProperties: false,
  required: ["path", "startOffsetMs"],
  properties: {
    path: { type: "string", minLength: 1, maxLength: 1_024 },
    startOffsetMs: { type: "integer", minimum: 0, maximum: MAX_DURATION_MS },
  },
} as const;

const sessionSchema = {
  type: "object",
  additionalProperties: true,
  required: ["schemaVersion", "sessionId", "state", "durationMs", "project", "artifacts", "privacy"],
  properties: {
    schemaVersion: { const: "1.0" },
    sessionId: { type: "string", minLength: 1, maxLength: 128 },
    state: { type: "string", minLength: 1, maxLength: 32 },
    durationMs: { type: "integer", minimum: 1, maximum: MAX_DURATION_MS },
    project: {
      type: "object",
      additionalProperties: false,
      properties: {
        name: { type: ["string", "null"], maxLength: 512 },
        rootPath: { type: ["string", "null"], maxLength: 4_096 },
        gitBranch: { type: ["string", "null"], maxLength: 512 },
        headCommit: { type: ["string", "null"], maxLength: 128 },
      },
    },
    artifacts: {
      type: "object",
      additionalProperties: false,
      required: ["eventLog", "frameIndex", "microphone"],
      properties: {
        recording: artifactSchema,
        microphone: artifactSchema,
        eventLog: artifactSchema,
        frameIndex: artifactSchema,
        transcript: artifactSchema,
        taskSpec: artifactSchema,
      },
    },
    privacy: {
      type: "object",
      additionalProperties: false,
      required: ["recordsRawKeystrokesLocally", "uploadsRawKeystrokes", "uploadsRecordingFile", "safetyIdentifier"],
      properties: {
        recordsRawKeystrokesLocally: { type: "boolean" },
        recordsTypingActivityLocally: { type: "boolean" },
        recordsSafeShortcutsLocally: { type: "boolean" },
        evidenceFramesIncludeCamera: { type: "boolean" },
        uploadsRawKeystrokes: { type: "boolean" },
        uploadsRecordingFile: { type: "boolean" },
        safetyIdentifier: { type: "string", minLength: 1, maxLength: 128 },
      },
    },
  },
} as const;

const eventSchema = {
  type: "object",
  additionalProperties: false,
  required: ["sequence", "tMs", "kind"],
  properties: {
    sequence: { type: "integer", minimum: 0, maximum: 10_000_000 },
    tMs: { type: "integer", minimum: 0, maximum: MAX_DURATION_MS + 1_000 },
    kind: {
      enum: ["mouseDown", "mouseUp", "mouseDragged", "scroll", "keyDown", "keyUp", "modifiersChanged", "captureGap"],
    },
    position: {
      type: "object",
      additionalProperties: false,
      required: ["displayNormalizedTopLeft"],
      properties: {
        globalPoints: pointSchema,
        displayLocalPoints: pointSchema,
        displayNormalizedTopLeft: pointSchema,
        capturePixels: pointSchema,
      },
    },
    mouseButton: { type: "string", maxLength: 16 },
    scrollDeltaX: { type: "number" },
    scrollDeltaY: { type: "number" },
    keyCode: { type: "integer", minimum: 0, maximum: 65_535 },
    characters: { type: "string", maxLength: 64 },
    shortcut: { type: "string", maxLength: 80 },
    modifiers: {
      type: "array",
      maxItems: 8,
      uniqueItems: true,
      items: { enum: ["command", "control", "option", "shift", "capsLock", "fn"] },
    },
    context: {
      type: "object",
      additionalProperties: false,
      properties: {
        appName: { type: "string", maxLength: 512 },
        bundleIdentifier: { type: "string", maxLength: 512 },
        windowTitle: { type: "string", maxLength: 2_048 },
      },
    },
    reason: { type: "string", maxLength: 512 },
  },
} as const;

const frameCandidateSchema = {
  type: "object",
  additionalProperties: false,
  required: ["file", "tMs", "kind"],
  properties: {
    file: { type: "string", minLength: 1, maxLength: 512 },
    tMs: { type: "integer", minimum: 0, maximum: MAX_DURATION_MS + 1_000 },
    kind: { enum: ["first", "last", "click", "afterClick", "scrollSettled", "typingSettled", "periodic"] },
    clickPosition: pointSchema,
  },
} as const;

const ajv = new Ajv({ allErrors: true, strict: true });
const validateSession = ajv.compile<SessionManifest>(sessionSchema);
const validateEvent = ajv.compile<InputEvent>(eventSchema);
const validateFrameCandidate = ajv.compile<FrameCandidate>(frameCandidateSchema);

export interface ValidatedManifest {
  rootPath: string;
  manifest: SessionManifest & { durationMs: number };
}

export interface ValidatedSessionBundle extends ValidatedManifest {
  events: InputEvent[];
  candidates: FrameCandidate[];
  microphonePath: string;
  framePaths: Map<string, string>;
}

export async function loadValidatedManifest(sessionPath: string): Promise<ValidatedManifest> {
  const rootStatus = await lstat(sessionPath).catch(() => undefined);
  if (!rootStatus?.isDirectory() || rootStatus.isSymbolicLink()) {
    throw new Error("Session path must be a real directory, not a symbolic link");
  }
  const rootPath = await realpath(sessionPath);
  const manifestPath = await regularArtifact(rootPath, "session.json", "session manifest", MAX_MANIFEST_BYTES);
  const manifest = await readJSON<SessionManifest>(manifestPath, validateSession, "session.json");
  return { rootPath, manifest: manifest as SessionManifest & { durationMs: number } };
}

export async function loadValidatedSessionBundle(validated: ValidatedManifest): Promise<ValidatedSessionBundle> {
  const { rootPath, manifest } = validated;
  const microphone = manifest.artifacts.microphone;
  if (!microphone) throw new Error("Session manifest is missing the microphone artifact");
  if (microphone.startOffsetMs > manifest.durationMs) {
    throw new Error("Microphone start offset is outside the session timeline");
  }
  const microphonePath = await regularArtifact(rootPath, microphone.path, "microphone audio", MAX_AUDIO_BYTES, true);
  const audioStatus = await lstat(microphonePath);
  if (audioStatus.size === 0) throw new Error("Microphone audio is empty");

  const eventsPath = await regularArtifact(rootPath, manifest.artifacts.eventLog.path, "event log", MAX_EVENTS_BYTES);
  const events = await readEvents(eventsPath, manifest.durationMs);
  const frameIndexPath = await regularArtifact(
    rootPath,
    manifest.artifacts.frameIndex.path,
    "frame index",
    MAX_FRAME_INDEX_BYTES,
  );
  const candidates = await readFrameCandidates(frameIndexPath, manifest.durationMs);
  const framePaths = new Map<string, string>();
  for (const candidate of candidates) {
    if (!/^frames\/[A-Za-z0-9._-]+\.jpe?g$/i.test(candidate.file)) {
      throw new Error(`Evidence frame path is invalid: ${candidate.file}`);
    }
    if (framePaths.has(candidate.file)) throw new Error(`Duplicate evidence frame path: ${candidate.file}`);
    const framePath = await regularArtifact(rootPath, candidate.file, "evidence frame", MAX_FRAME_BYTES, true);
    await validateJPEG(framePath);
    framePaths.set(candidate.file, framePath);
  }

  return { rootPath, manifest, events, candidates, microphonePath, framePaths };
}

async function readJSON<T>(path: string, validate: ValidateFunction<T>, label: string): Promise<T> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(await Bun.file(path).text());
  } catch {
    throw new Error(`${label} is not valid JSON`);
  }
  if (!validate(parsed)) throw new Error(`${label} schema validation failed: ${ajv.errorsText(validate.errors)}`);
  return parsed;
}

async function readEvents(path: string, durationMs: number): Promise<InputEvent[]> {
  const text = await Bun.file(path).text();
  const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
  if (lines.length > MAX_EVENTS) throw new Error(`Event count exceeds ${MAX_EVENTS}`);
  const events: InputEvent[] = [];
  let previousSequence = -1;
  for (const [index, line] of lines.entries()) {
    if (Buffer.byteLength(line) > MAX_EVENT_LINE_BYTES) throw new Error(`Event line ${index + 1} exceeds the size limit`);
    let event: unknown;
    try { event = JSON.parse(line); } catch { throw new Error(`Event line ${index + 1} is not valid JSON`); }
    if (!validateEvent(event)) {
      throw new Error(`Event line ${index + 1} schema validation failed: ${ajv.errorsText(validateEvent.errors)}`);
    }
    if (event.sequence <= previousSequence) throw new Error("Event sequences must be strictly increasing");
    if (event.tMs > durationMs + 1_000) throw new Error(`Event line ${index + 1} is outside the session timeline`);
    const normalized = event.position?.displayNormalizedTopLeft;
    if (normalized && !isNormalizedPoint(normalized)) throw new Error(`Event line ${index + 1} has invalid normalized coordinates`);
    previousSequence = event.sequence;
    events.push(event);
  }
  return events;
}

async function readFrameCandidates(path: string, durationMs: number): Promise<FrameCandidate[]> {
  const candidates = await readJSON<FrameCandidate[]>(
    path,
    ajv.compile<FrameCandidate[]>({ type: "array", maxItems: MAX_FRAME_CANDIDATES, items: frameCandidateSchema }),
    "frames/index.json",
  );
  for (const [index, candidate] of candidates.entries()) {
    if (candidate.tMs > durationMs + 1_000) throw new Error(`Frame candidate ${index} is outside the session timeline`);
    if (candidate.clickPosition && !isNormalizedPoint(candidate.clickPosition)) {
      throw new Error(`Frame candidate ${index} has invalid click coordinates`);
    }
  }
  return candidates;
}

async function regularArtifact(
  rootPath: string,
  relativePath: string,
  label: string,
  maximumBytes: number,
  rejectEmpty = false,
): Promise<string> {
  if (isAbsolute(relativePath) || relativePath.includes("\0")) throw new Error(`${label} path must be relative`);
  const target = resolve(rootPath, relativePath);
  const relation = relative(rootPath, target);
  if (relation === ".." || relation.startsWith(`..${sep}`) || isAbsolute(relation)) {
    throw new Error(`${label} escapes the session directory`);
  }
  const status = await lstat(target).catch(() => undefined);
  if (!status) throw new Error(`${label} is missing`);
  if (status.isSymbolicLink()) throw new Error(`${label} must not be a symbolic link`);
  if (!status.isFile()) throw new Error(`${label} must be a regular file`);
  const canonical = await realpath(target);
  if (canonical !== target) throw new Error(`${label} path contains a symbolic link`);
  const canonicalRelation = relative(rootPath, canonical);
  if (canonicalRelation === ".." || canonicalRelation.startsWith(`..${sep}`) || isAbsolute(canonicalRelation)) {
    throw new Error(`${label} resolves outside the session directory`);
  }
  if (status.size > maximumBytes) throw new Error(`${label} exceeds the ${formatBytes(maximumBytes)} limit`);
  if (rejectEmpty && status.size === 0) throw new Error(`${label} is empty`);
  return canonical;
}

async function validateJPEG(path: string): Promise<void> {
  const status = await lstat(path);
  const handle = await open(path, "r");
  try {
    const length = Math.min(status.size, MAX_JPEG_HEADER_BYTES);
    const bytes = Buffer.alloc(length);
    const { bytesRead } = await handle.read(bytes, 0, length, 0);
    const header = bytes.subarray(0, bytesRead);
    if (header.length < 4 || header[0] !== 0xff || header[1] !== 0xd8) {
      throw new Error("Evidence frame is not a JPEG file");
    }
    const dimensions = jpegDimensions(header);
    if (!dimensions) throw new Error("Evidence frame JPEG dimensions are missing or invalid");
    if (dimensions.width > MAX_IMAGE_DIMENSION || dimensions.height > MAX_IMAGE_DIMENSION
      || dimensions.width * dimensions.height > MAX_IMAGE_PIXELS) {
      throw new Error("Evidence frame dimensions exceed the safety limit");
    }
  } finally {
    await handle.close();
  }
}

function jpegDimensions(data: Uint8Array): { width: number; height: number } | undefined {
  let offset = 2;
  while (offset + 3 < data.length) {
    while (offset < data.length && data[offset] === 0xff) offset += 1;
    if (offset >= data.length) return undefined;
    const marker = data[offset++]!;
    if (marker === 0xd9 || marker === 0xda) return undefined;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 1 >= data.length) return undefined;
    const length = (data[offset]! << 8) | data[offset + 1]!;
    if (length < 2 || offset + length > data.length) return undefined;
    if (isStartOfFrame(marker)) {
      if (length < 7) return undefined;
      const height = (data[offset + 3]! << 8) | data[offset + 4]!;
      const width = (data[offset + 5]! << 8) | data[offset + 6]!;
      return width > 0 && height > 0 ? { width, height } : undefined;
    }
    offset += length;
  }
  return undefined;
}

function isStartOfFrame(marker: number): boolean {
  return marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker);
}

function isNormalizedPoint(point: { x: number; y: number }): boolean {
  return Number.isFinite(point.x) && Number.isFinite(point.y)
    && point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1;
}

function formatBytes(value: number): string {
  return `${Math.round(value / (1024 * 1024))} MB`;
}
