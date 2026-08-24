import OpenAI, { toFile } from "openai";
import type { ResponseInputContent } from "openai/resources/responses/responses";
import { basename } from "node:path";
import { taskSpecSchema, validateTaskSpec } from "./schema";
import { withRetry } from "./retry";
import type {
  FrameCandidate,
  SanitizedEvent,
  SessionManifest,
  RawTranscriptDocument,
  TaskSpec,
  TranscriptDocument,
} from "./types";

export interface UnderstandingInput {
  manifest: SessionManifest;
  transcript: TranscriptDocument;
  timeline: SanitizedEvent[];
  frames: Array<FrameCandidate & { absolutePath: string }>;
}

export interface AIClient {
  transcribe(audioPath: string): Promise<RawTranscriptDocument>;
  understand(input: UnderstandingInput): Promise<TaskSpec>;
}

export class OpenAIClient implements AIClient {
  private readonly client: OpenAI;

  constructor(apiKey: string) {
    this.client = new OpenAI({
      apiKey,
      baseURL: "https://api.openai.com/v1",
      maxRetries: 0,
      timeout: 90_000,
    });
  }

  async transcribe(audioPath: string): Promise<RawTranscriptDocument> {
    const startedAt = performance.now();
    const upload = await toFile(Bun.file(audioPath), "microphone.m4a", { type: "audio/mp4" });
    const result = await withRetry(() =>
      this.client.audio.transcriptions
        .create({
          file: upload,
          model: "whisper-1",
          response_format: "verbose_json",
          timestamp_granularities: ["word"],
        })
        .withResponse(),
    );
    safeDiagnostic({
      stage: "transcription",
      latencyMs: Math.round(performance.now() - startedAt),
      model: "whisper-1",
      requestId: result.request_id,
      usage: result.data.usage ?? null,
    });
    return {
      text: result.data.text,
      language: result.data.language ?? null,
      words: (result.data.words ?? []).map(({ word, start, end }) => ({ word, start, end })),
    };
  }

  async understand(input: UnderstandingInput): Promise<TaskSpec> {
    const content: ResponseInputContent[] = [
      {
        type: "input_text",
        text: JSON.stringify({
          sessionId: input.manifest.sessionId,
          durationMs: input.manifest.durationMs ?? null,
          project: {
            name: input.manifest.project.name,
            gitBranch: input.manifest.project.gitBranch,
            headCommit: input.manifest.project.headCommit,
          },
          transcript: input.transcript,
          timeline: input.timeline,
          frames: input.frames.map(({ file, tMs, kind, clickPosition }) => ({
            file,
            tMs,
            kind,
            clickPosition,
          })),
        }),
      },
    ];

    for (const frame of input.frames) {
      const data = Buffer.from(await Bun.file(frame.absolutePath).arrayBuffer()).toString("base64");
      content.push({
        type: "input_text",
        text: `근거 프레임 ${frame.file}, tMs=${frame.tMs}, kind=${frame.kind}`,
      });
      content.push({
        type: "input_image",
        image_url: `data:image/jpeg;base64,${data}`,
        detail: "original",
      });
    }

    const schema = structuredClone(taskSpecSchema) as Record<string, unknown>;
    delete schema.$schema;
    delete schema.$id;
    delete schema.title;

    const startedAt = performance.now();
    const result = await withRetry(() =>
      this.client.responses
        .create({
          model: "gpt-5.6",
          store: false,
          safety_identifier: input.manifest.privacy.safetyIdentifier,
          reasoning: { effort: "medium" },
          instructions: [
            "당신은 웹 UI 수정 지시를 실행 가능한 TaskSpec으로 바꾸는 제품 분석가입니다.",
            "goal, summary, task title, target description, change instruction, constraints, acceptance criteria, assumptions, unresolved questions는 모두 자연스러운 한국어로 작성하세요.",
            "사용자가 음성으로 명시했거나 클릭·프레임으로 강하게 뒷받침되는 변경만 task로 만드세요. 추측한 변경은 만들지 마세요.",
            "각 task에는 최소 하나의 실제 transcript/frame/click evidence를 연결하고 숫자, 반응형 조건, 위치 표현을 보존하세요.",
            "프레임 경로는 입력에 제공된 file 문자열만 사용하세요. raw 키 문자, 비밀번호, 로컬 절대 경로, 소스 코드는 제공되지 않으며 추론하지 마세요.",
            "소스 코드 구현 방법이 불명확하면 change.instruction은 관찰 가능한 UI 결과 중심으로 쓰고 unresolvedQuestions에 질문을 남기세요.",
          ].join("\n"),
          input: [{ role: "user", content }],
          text: {
            format: {
              type: "json_schema",
              name: "soom_taskspec_v1",
              description: "화면, 음성, 클릭 근거에 기반한 한국어 웹 UI 변경 TaskSpec",
              strict: true,
              schema,
            },
          },
          max_output_tokens: 12_000,
        })
        .withResponse(),
    );

    safeDiagnostic({
      stage: "understanding",
      latencyMs: Math.round(performance.now() - startedAt),
      model: "gpt-5.6",
      requestId: result.request_id,
      usage: result.data.usage ?? null,
    });
    if (result.data.status !== "completed") {
      const reason = result.data.incomplete_details?.reason ?? result.data.error?.code ?? result.data.status;
      throw new Error(`OpenAI response did not complete: ${reason}`);
    }
    if (!result.data.output_text) throw new Error("The model returned no TaskSpec output");
    const parsed: unknown = JSON.parse(result.data.output_text);
    validateTaskSpec(parsed);
    return parsed;
  }
}

export function normalizeModelResult(
  taskSpec: TaskSpec,
  manifest: SessionManifest,
  selectedFrames: FrameCandidate[],
): TaskSpec {
  if (taskSpec.sessionId !== manifest.sessionId) {
    throw new Error("TaskSpec sessionId does not match the source session");
  }
  const allowedFrames = new Set(selectedFrames.map((frame) => frame.file));
  const normalized: TaskSpec = structuredClone(taskSpec);
  normalized.project = canonicalProject(manifest.project);
  for (const task of normalized.tasks) {
    for (const evidence of task.evidence) {
      if (evidence.frame && !allowedFrames.has(evidence.frame)) evidence.frame = null;
      if (evidence.frame) evidence.frame = evidence.frame.replaceAll("\\", "/");
      if (evidence.frame?.startsWith("/") || evidence.frame?.includes("../")) evidence.frame = null;
    }
  }
  validateTaskSpec(normalized);
  return normalized;
}

export function canonicalProject(project: Partial<TaskSpec["project"]>): TaskSpec["project"] {
  return {
    name: project.name ?? null,
    rootPath: project.rootPath ?? null,
    gitBranch: project.gitBranch ?? null,
    headCommit: project.headCommit ?? null,
  };
}

function safeDiagnostic(value: {
  stage: string;
  latencyMs: number;
  model: string;
  requestId: string | null;
  usage: unknown;
}) {
  process.stderr.write(`${JSON.stringify(value)}\n`);
}

export function frameBasename(value: string): string {
  return basename(value);
}
