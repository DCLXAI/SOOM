import { join } from "node:path";
import { loadValidatedManifest, loadValidatedSessionBundle } from "./bundle-validation";
import { exportResults, writeInternalResults } from "./files";
import { selectFrames } from "./frames";
import { canonicalProject, normalizeModelResult, type AIClient } from "./openai-client";
import { sanitizeEvents } from "./privacy";
import { validateTaskSpecSemantics } from "./semantic-validation";
import { canonicalizeTranscript } from "./transcript";
import type { ExportFailure, ProgressEvent, SessionManifest, TaskSpec } from "./types";

export interface ProcessOptions {
  sessionPath: string;
  exportPath: string;
  client: AIClient;
  emit?: (event: ProgressEvent) => void;
}

export async function processSession(options: ProcessOptions): Promise<{
  taskSpec: TaskSpec;
  exportPath?: string;
  exportFailure?: ExportFailure;
}> {
  const emit = options.emit ?? (() => undefined);
  emit({ type: "progress", stage: "validation", fraction: 0.02 });
  const validatedManifest = await loadValidatedManifest(options.sessionPath);
  const { manifest } = validatedManifest;
  assertPrivacyContract(manifest);
  const bundle = await loadValidatedSessionBundle(validatedManifest);

  emit({ type: "progress", stage: "transcription", fraction: 0.08 });
  const rawTranscript = await options.client.transcribe(bundle.microphonePath);
  const transcript = canonicalizeTranscript(
    rawTranscript,
    manifest.artifacts.microphone?.startOffsetMs ?? 0,
    manifest.durationMs,
  );

  emit({ type: "progress", stage: "timeline", fraction: 0.35 });
  const sanitizedTimeline = sanitizeEvents(bundle.events);
  const selected = selectFrames(bundle.candidates, 12).map((frame) => ({
    ...frame,
    absolutePath: bundle.framePaths.get(frame.file)!,
  }));

  emit({ type: "progress", stage: "understanding", fraction: 0.5 });
  const modelSpec = await options.client.understand({
    manifest: modelManifest(manifest),
    transcript,
    timeline: sanitizedTimeline,
    frames: selected,
  });
  const taskSpec = normalizeModelResult(modelSpec, manifest, selected);
  validateTaskSpecSemantics(taskSpec, {
    sessionId: manifest.sessionId,
    durationMs: manifest.durationMs,
    allowedFrames: new Set(selected.map((frame) => frame.file)),
  });

  emit({ type: "progress", stage: "export", fraction: 0.86 });
  await writeInternalResults(bundle.rootPath, transcript, taskSpec);
  let exportedPath: string | undefined;
  let exportFailure: ExportFailure | undefined;
  try {
    exportedPath = await exportResults(options.exportPath, taskSpec, selected);
  } catch (error) {
    exportFailure = exportFailureDetails(error);
  }

  emit({
    type: "complete",
    stage: "export",
    fraction: 1,
    taskSpecPath: join(bundle.rootPath, "taskspec.json"),
    exportPath: exportedPath,
    exportStatus: exportedPath ? "complete" : "failed",
    exportError: exportFailure,
    message: exportedPath ? "complete" : "TaskSpec saved in session; export failed and can be retried separately",
  });
  return { taskSpec, exportPath: exportedPath, exportFailure };
}

function modelManifest(manifest: SessionManifest): SessionManifest {
  return {
    ...manifest,
    project: { ...canonicalProject(manifest.project), rootPath: null },
  };
}

function assertPrivacyContract(manifest: SessionManifest) {
  if (manifest.privacy.uploadsRawKeystrokes || manifest.privacy.uploadsRecordingFile) {
    throw new Error("Session privacy contract permits an unsupported upload");
  }
  if (manifest.privacy.evidenceFramesIncludeCamera !== false) {
    throw new Error("Session evidence frames may contain the camera and cannot be uploaded");
  }
  if (!manifest.privacy.safetyIdentifier) throw new Error("Session safety identifier is missing");
}

export function exportFailureDetails(error: unknown): ExportFailure {
  const code = typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code ?? "")
    : "";
  switch (code) {
    case "EACCES":
    case "EPERM":
      return { code: "permission", message: "Export folder permission was denied", retryable: true };
    case "ENOSPC":
      return { code: "diskFull", message: "The export disk does not have enough free space", retryable: true };
    case "EROFS":
      return { code: "readOnly", message: "The export destination is read-only", retryable: true };
    case "ENOTDIR":
    case "EEXIST":
    case "EINVAL":
      return { code: "invalidDestination", message: "The export destination is not a writable folder", retryable: true };
    default:
      return { code: "unknown", message: "The export could not be completed", retryable: true };
  }
}
