import { describe, expect, test } from "bun:test";
import { agentTaskMarkdown, taskSpecMarkdown } from "../src/markdown";
import { validateTaskSpec } from "../src/schema";
import { fixtureTaskSpec } from "./fixtures";

describe("TaskSpec schema and Markdown", () => {
  test("Korean fixture passes the strict local schema", () => {
    expect(() => validateTaskSpec(fixtureTaskSpec())).not.toThrow();
  });

  test("malformed output fails validation", () => {
    const malformed = { ...fixtureTaskSpec(), tasks: [{ title: "missing fields" }] };
    expect(() => validateTaskSpec(malformed)).toThrow(/schema validation/i);
  });

  test("human and agent handoff Markdown are actionable", () => {
    const spec = fixtureTaskSpec();
    const human = taskSpecMarkdown(spec);
    const agent = agentTaskMarkdown(spec);
    expect(human).toContain("Hero 높이 축소");
    expect(human).toContain("완료 기준");
    expect(agent).toContain("Codex / Claude Code 작업 지시");
    expect(agent).toContain("관련 테스트와 빌드를 실행하세요");
  });
});
