import { basename, join } from "node:path";
import { chmod, lstat, mkdir, readdir, rename, rm } from "node:fs/promises";
import type { FrameCandidate, TaskSpec, TranscriptDocument } from "./types";
import { agentTaskMarkdown, taskSpecMarkdown } from "./markdown";

const encoder = new TextEncoder();

export async function atomicWrite(path: string, contents: string): Promise<void> {
  const temporary = `${path}.tmp-${crypto.randomUUID()}`;
  await Bun.write(temporary, contents);
  await chmod(temporary, 0o600);
  await rename(temporary, path);
  await chmod(path, 0o600);
}

export async function writeInternalResults(
  sessionPath: string,
  transcript: TranscriptDocument,
  spec: TaskSpec,
): Promise<void> {
  await atomicWrite(join(sessionPath, "transcript.json"), `${JSON.stringify(transcript, null, 2)}\n`);
  await atomicWrite(join(sessionPath, "taskspec.json"), `${JSON.stringify(spec, null, 2)}\n`);
  await atomicWrite(join(sessionPath, "taskspec.md"), taskSpecMarkdown(spec));
  await atomicWrite(join(sessionPath, "AGENT_TASK.md"), agentTaskMarkdown(spec));
}

export async function exportResults(
  exportRoot: string,
  spec: TaskSpec,
  selectedFrames: Array<FrameCandidate & { absolutePath: string }>,
): Promise<string> {
  await mkdir(exportRoot, { recursive: true, mode: 0o700 });
  await cleanupStaleExportDirectories(exportRoot);
  const stamp = new Date().toISOString().replaceAll(":", "-").replace(/\.\d{3}Z$/, "Z");
  const baseName = `${stamp}-${spec.sessionId.slice(0, 8)}`;
  let finalPath = join(exportRoot, baseName);
  let suffix = 1;
  while (await exists(finalPath)) finalPath = join(exportRoot, `${baseName}-${suffix++}`);

  const staging = join(exportRoot, `.soom-${crypto.randomUUID()}.tmp`);
  await mkdir(join(staging, "evidence"), { recursive: true, mode: 0o700 });
  try {
    const exportedSpec: TaskSpec = structuredClone(spec);
    const copied = new Map<string, string>();
    for (const frame of selectedFrames) {
      const name = basename(frame.file);
      const relative = `evidence/${name}`;
      copied.set(frame.file, relative);
      await Bun.write(join(staging, relative), Bun.file(frame.absolutePath));
      await chmod(join(staging, relative), 0o600);
    }
    for (const task of exportedSpec.tasks) {
      for (const evidence of task.evidence) {
        if (evidence.frame) evidence.frame = copied.get(evidence.frame) ?? null;
      }
    }

    await atomicWrite(join(staging, "taskspec.json"), `${JSON.stringify(exportedSpec, null, 2)}\n`);
    await atomicWrite(join(staging, "taskspec.md"), taskSpecMarkdown(exportedSpec));
    await atomicWrite(join(staging, "AGENT_TASK.md"), agentTaskMarkdown(exportedSpec));
    await rename(staging, finalPath);
    await chmod(finalPath, 0o700);
    return finalPath;
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error;
  }
}

export async function cleanupStaleExportDirectories(
  exportRoot: string,
  olderThanMs = 24 * 60 * 60 * 1_000,
  nowMs = Date.now(),
): Promise<void> {
  const names = await readdir(exportRoot).catch(() => [] as string[]);
  const stagingPattern = /^\.soom-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.tmp$/i;
  for (const name of names) {
    if (!stagingPattern.test(name)) continue;
    const candidate = join(exportRoot, name);
    const status = await lstat(candidate).catch(() => undefined);
    if (!status?.isDirectory() || status.isSymbolicLink()) continue;
    if (nowMs - status.mtimeMs >= olderThanMs) await rm(candidate, { recursive: true, force: true });
  }
}

async function exists(path: string): Promise<boolean> {
  return Bun.file(path).exists() || (await directoryExists(path));
}

async function directoryExists(path: string): Promise<boolean> {
  try {
    const stat = await import("node:fs/promises").then((fs) => fs.stat(path));
    return stat.isDirectory();
  } catch {
    return false;
  }
}

export function encodedBytes(value: string): number {
  return encoder.encode(value).byteLength;
}
