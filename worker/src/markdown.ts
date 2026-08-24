import type { TaskSpec } from "./types";

export function taskSpecMarkdown(spec: TaskSpec): string {
  const lines: string[] = [
    `# ${spec.goal}`,
    "",
    spec.summary,
    "",
    `- 세션: \`${spec.sessionId}\``,
    `- 프로젝트: ${spec.project.name ?? "지정 안 함"}`,
    `- 브랜치: \`${spec.project.gitBranch ?? "알 수 없음"}\``,
    `- HEAD: \`${spec.project.headCommit ?? "알 수 없음"}\``,
    "",
    "## 작업",
    "",
  ];

  for (const [index, task] of spec.tasks.entries()) {
    lines.push(
      `### ${index + 1}. ${task.title}`,
      "",
      `- 대상: ${task.target.description}`,
      `- 변경: ${task.change.instruction}`,
    );
    if (task.change.value) lines.push(`- 값: ${task.change.value}`);
    if (task.constraints.length) {
      lines.push("- 제약:", ...task.constraints.map((item) => `  - ${item}`));
    }
    lines.push("- 완료 기준:", ...task.acceptanceCriteria.map((item) => `  - ${item}`));
    lines.push("- 근거:");
    for (const evidence of task.evidence) {
      const parts = [`${evidence.kind}@${(evidence.tMs / 1_000).toFixed(1)}s`];
      if (evidence.quote) parts.push(`“${evidence.quote}”`);
      if (evidence.frame) parts.push(evidence.frame);
      if (evidence.position) parts.push(`(${evidence.position.x.toFixed(3)}, ${evidence.position.y.toFixed(3)})`);
      lines.push(`  - ${parts.join(" · ")}`);
    }
    lines.push(`- 신뢰도: ${Math.round(task.confidence * 100)}%`, "");
  }

  if (spec.unresolvedQuestions.length) {
    lines.push("## 확인할 질문", "", ...spec.unresolvedQuestions.map((question) => `- ${question}`), "");
  }
  return `${lines.join("\n").trim()}\n`;
}

export function agentTaskMarkdown(spec: TaskSpec): string {
  const lines: string[] = [
    "# Codex / Claude Code 작업 지시",
    "",
    "> SOOM이 화면 녹화, 음성, 클릭 근거로 생성한 작업입니다. 근거에 없는 변경은 추가하지 마세요.",
    "",
    "## 작업 위치",
    "",
    spec.project.rootPath
      ? `로컬 프로젝트 폴더: \`${spec.project.rootPath}\``
      : "이 파일을 수정할 저장소 루트에서 에이전트를 실행하세요.",
    "",
    `브랜치: \`${spec.project.gitBranch ?? "현재 브랜치"}\`  `,
    `기준 HEAD: \`${spec.project.headCommit ?? "확인 필요"}\``,
    "",
    "## 목표",
    "",
    spec.goal,
    "",
    spec.summary,
    "",
    "## 구현할 작업",
    "",
  ];

  for (const [index, task] of spec.tasks.entries()) {
    lines.push(
      `### ${index + 1}. ${task.title}`,
      "",
      `대상: ${task.target.description}`,
      "",
      task.change.instruction,
      "",
    );
    if (task.change.value) lines.push(`구체 값: ${task.change.value}`, "");
    if (task.constraints.length) {
      lines.push("제약 조건:", ...task.constraints.map((item) => `- ${item}`), "");
    }
    lines.push("완료 기준:", ...task.acceptanceCriteria.map((item) => `- ${item}`), "");
  }

  if (spec.unresolvedQuestions.length) {
    lines.push("## 구현 전 확인이 필요한 사항", "", ...spec.unresolvedQuestions.map((item) => `- ${item}`), "");
  }
  lines.push(
    "## 에이전트 수행 규칙",
    "",
    "1. 저장소 구조와 기존 스타일을 먼저 확인하세요.",
    "2. 위 작업에 필요한 최소 범위만 수정하세요.",
    "3. 관련 테스트와 빌드를 실행하세요.",
    "4. 변경 파일, 검증 결과, 남은 질문을 마지막에 요약하세요.",
    "5. 시각 근거가 필요하면 함께 내보낸 `evidence/` 이미지를 확인하세요.",
    "",
  );
  return lines.join("\n");
}
