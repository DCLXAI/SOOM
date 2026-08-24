import type { SessionManifest, TaskSpec } from "../src/types";

export function fixtureManifest(rootPath: string | null = "/private/project/showtell"): SessionManifest {
  return {
    schemaVersion: "1.0",
    sessionId: "fixture-session",
    state: "processing",
    durationMs: 12_000,
    project: {
      name: "landing-page",
      rootPath,
      gitBranch: "feature/hero",
      headCommit: "0123456789abcdef",
    },
    artifacts: {
      microphone: { path: "microphone.m4a", startOffsetMs: 0 },
      eventLog: { path: "events.ndjson", startOffsetMs: 0 },
      frameIndex: { path: "frames/index.json", startOffsetMs: 0 },
    },
    privacy: {
      recordsRawKeystrokesLocally: false,
      recordsTypingActivityLocally: true,
      recordsSafeShortcutsLocally: true,
      evidenceFramesIncludeCamera: false,
      uploadsRawKeystrokes: false,
      uploadsRecordingFile: false,
      safetyIdentifier: "anonymous-fixture-user",
    },
  };
}

export function fixtureTaskSpec(): TaskSpec {
  return {
    schemaVersion: "1.0",
    sessionId: "fixture-session",
    project: {
      name: "landing-page",
      rootPath: null,
      gitBranch: "feature/hero",
      headCommit: "0123456789abcdef",
    },
    goal: "랜딩 페이지의 hero와 모바일 카드 레이아웃 수정",
    summary: "hero 높이를 줄이고 CTA 위치 및 모바일 카드 열 수를 조정한다.",
    tasks: [
      {
        id: "task-1",
        title: "Hero 높이 축소",
        target: {
          description: "랜딩 페이지 상단 hero 섹션",
          app: "Chrome",
          windowTitle: "Landing Page",
          region: {
            x: 0.1,
            y: 0.1,
            width: 0.8,
            height: 0.35,
            coordinateSpace: "displayNormalizedTopLeft",
          },
        },
        change: {
          instruction: "현재 hero 높이를 약 30% 줄인다.",
          value: "약 30% 감소",
        },
        constraints: ["데스크톱의 기존 콘텐츠 순서를 유지한다."],
        acceptanceCriteria: ["동일한 viewport에서 hero의 세로 높이가 기존 대비 약 30% 작다."],
        evidence: [
          {
            kind: "speech",
            tMs: 3_200,
            frame: null,
            quote: "여기 hero가 너무 커. 높이를 30% 줄여줘.",
            position: null,
          },
        ],
        confidence: 0.94,
        assumptions: [],
      },
    ],
    unresolvedQuestions: [],
  };
}
