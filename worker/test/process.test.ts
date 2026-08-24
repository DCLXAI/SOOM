import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { AIClient, UnderstandingInput } from "../src/openai-client";
import { processSession } from "../src/process";
import type { RawTranscriptDocument } from "../src/types";
import { fixtureManifest, fixtureTaskSpec } from "./fixtures";

const temporaryPaths: string[] = [];
afterEach(async () => {
  await Promise.all(temporaryPaths.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("session processing", () => {
  test("composite evidence frames that may contain camera video are rejected", async () => {
    const root = await mkdtemp(join(tmpdir(), "showtell-worker-camera-evidence-"));
    temporaryPaths.push(root);
    const session = join(root, "session");
    await mkdir(session, { recursive: true });
    const manifest = fixtureManifest();
    manifest.privacy.evidenceFramesIncludeCamera = true;
    await Bun.write(join(session, "session.json"), JSON.stringify(manifest));
    const client: AIClient = {
      transcribe: async () => ({ text: "", language: null, words: [] }),
      understand: async () => fixtureTaskSpec(),
    };

    await expect(processSession({ sessionPath: session, exportPath: join(root, "output"), client }))
      .rejects.toThrow("evidence frames may contain the camera");
  });

  test("typed password and local path never enter the model request or exports", async () => {
    const root = await mkdtemp(join(tmpdir(), "showtell-worker-test-"));
    temporaryPaths.push(root);
    const session = join(root, "session");
    const output = join(root, "output");
    await mkdir(join(session, "frames"), { recursive: true });
    const canary = "CANARY-password-7391";
    const localPath = "/private/secret/customer-project";
    const windowTitleCanary = "CANARY confidential customer roadmap";
    const manifest = fixtureManifest(localPath);
    manifest.artifacts.microphone!.startOffsetMs = 350;
    await Bun.write(join(session, "session.json"), JSON.stringify(manifest));
    await Bun.write(join(session, "microphone.m4a"), "fixture-audio");
    await Bun.write(join(session, "frames/index.json"), "[]");
    await Bun.write(
      join(session, "events.ndjson"),
      [...canary]
        .map((character, index) =>
          JSON.stringify({
            sequence: index,
            tMs: index * 60,
            kind: "keyDown",
            keyCode: index,
            characters: character,
            modifiers: [],
            context: { appName: "Chrome", windowTitle: windowTitleCanary },
          }),
        )
        .join("\n"),
    );

    let capturedRequest = "";
    let capturedTranscript: UnderstandingInput["transcript"] | undefined;
    const transcript: RawTranscriptDocument = {
      text: "여기 hero 높이를 30% 줄여줘. Keep the CTA visible.",
      language: "ko",
      words: [{ word: "여기", start: 0.2, end: 0.4 }],
    };
    const client: AIClient = {
      transcribe: async () => transcript,
      understand: async (input: UnderstandingInput) => {
        capturedRequest = JSON.stringify(input);
        capturedTranscript = input.transcript;
        return fixtureTaskSpec();
      },
    };

    const result = await processSession({ sessionPath: session, exportPath: output, client });
    expect(capturedRequest).not.toContain(canary);
    expect(capturedRequest).not.toContain(localPath);
    expect(capturedRequest).not.toContain(windowTitleCanary);
    expect(capturedRequest).not.toContain("windowTitle");
    expect(capturedRequest).not.toContain("recording.mp4");
    expect(capturedTranscript?.timeUnit).toBe("ms");
    expect(capturedTranscript?.words[0]).toEqual({ word: "여기", startMs: 550, endMs: 750 });
    expect(result.exportPath).toBeTruthy();

    const internalTaskSpec = await readFile(join(session, "taskspec.json"), "utf8");
    const exportedAgentTask = await readFile(join(result.exportPath!, "AGENT_TASK.md"), "utf8");
    expect(internalTaskSpec).not.toContain(canary);
    expect(exportedAgentTask).not.toContain(canary);
    expect(exportedAgentTask).toContain(localPath);
    expect(exportedAgentTask).toContain("Codex / Claude Code");
  });

  test("a session without a selected project exports explicit null project fields", async () => {
    const root = await mkdtemp(join(tmpdir(), "showtell-worker-no-project-"));
    temporaryPaths.push(root);
    const session = join(root, "session");
    const output = join(root, "output");
    await mkdir(join(session, "frames"), { recursive: true });
    const manifest = fixtureManifest();
    manifest.project = {};
    await Bun.write(join(session, "session.json"), JSON.stringify(manifest));
    await Bun.write(join(session, "microphone.m4a"), "fixture-audio");
    await Bun.write(join(session, "frames/index.json"), "[]");
    await Bun.write(join(session, "events.ndjson"), "");

    const client: AIClient = {
      transcribe: async () => ({ text: "버튼을 더 크게 해주세요.", language: "ko", words: [] }),
      understand: async () => fixtureTaskSpec(),
    };

    const result = await processSession({ sessionPath: session, exportPath: output, client });
    expect(result.taskSpec.project).toEqual({
      name: null,
      rootPath: null,
      gitBranch: null,
      headCommit: null,
    });
  });

  test("export failure is reported after one AI pass while session results remain available", async () => {
    const root = await mkdtemp(join(tmpdir(), "showtell-worker-export-failure-"));
    temporaryPaths.push(root);
    const session = join(root, "session");
    const invalidExportDestination = join(root, "not-a-directory");
    await mkdir(join(session, "frames"), { recursive: true });
    await Bun.write(join(session, "session.json"), JSON.stringify(fixtureManifest()));
    await Bun.write(join(session, "microphone.m4a"), "fixture-audio");
    await Bun.write(join(session, "frames/index.json"), "[]");
    await Bun.write(join(session, "events.ndjson"), "");
    await Bun.write(invalidExportDestination, "file");

    let understandCount = 0;
    const events: Array<{ type: string; exportStatus?: string; exportError?: { code: string } }> = [];
    const client: AIClient = {
      transcribe: async () => ({ text: "버튼을 줄여줘", language: "ko", words: [] }),
      understand: async () => {
        understandCount += 1;
        return fixtureTaskSpec();
      },
    };
    const result = await processSession({
      sessionPath: session,
      exportPath: invalidExportDestination,
      client,
      emit: (event) => events.push(event),
    });

    expect(understandCount).toBe(1);
    expect(result.exportPath).toBeUndefined();
    expect(result.exportFailure?.code).toBe("invalidDestination");
    expect(await Bun.file(join(session, "taskspec.json")).exists()).toBe(true);
    expect(events.at(-1)?.type).toBe("complete");
    expect(events.at(-1)?.exportStatus).toBe("failed");
    expect(events.at(-1)?.exportError?.code).toBe("invalidDestination");
  });
});
