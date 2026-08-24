import type { Evidence, TaskSpec } from "./types";

const MAX_TASKS = 50;
const MAX_ITEMS_PER_ARRAY = 50;
const MAX_SHORT_TEXT_BYTES = 2_048;
const MAX_LONG_TEXT_BYTES = 16_384;
const MAX_EVIDENCE_QUOTE_BYTES = 4_096;
const encoder = new TextEncoder();

export interface TaskSpecSemanticContext {
  sessionId: string;
  durationMs: number;
  allowedFrames: ReadonlySet<string>;
}

export function validateTaskSpecSemantics(spec: TaskSpec, context: TaskSpecSemanticContext): void {
  if (spec.sessionId !== context.sessionId) throw new Error("TaskSpec sessionId does not match the source session");
  if (!Number.isInteger(context.durationMs) || context.durationMs <= 0) throw new Error("Session duration is invalid");
  stringWithin(spec.sessionId, "sessionId", 128);
  nullableStringWithin(spec.project.name, "project.name", 512);
  nullableStringWithin(spec.project.rootPath, "project.rootPath", 4_096);
  nullableStringWithin(spec.project.gitBranch, "project.gitBranch", 512);
  nullableStringWithin(spec.project.headCommit, "project.headCommit", 128);
  stringWithin(spec.goal, "goal", MAX_LONG_TEXT_BYTES);
  stringWithin(spec.summary, "summary", MAX_LONG_TEXT_BYTES);
  stringArrayWithin(spec.unresolvedQuestions, "unresolvedQuestions");
  if (spec.tasks.length > MAX_TASKS) throw new Error(`TaskSpec has more than ${MAX_TASKS} tasks`);

  const identifiers = new Set<string>();
  for (const [index, task] of spec.tasks.entries()) {
    const label = `tasks[${index}]`;
    stringWithin(task.id, `${label}.id`, 128);
    if (identifiers.has(task.id)) throw new Error(`TaskSpec task id is duplicated: ${task.id}`);
    identifiers.add(task.id);
    stringWithin(task.title, `${label}.title`, MAX_SHORT_TEXT_BYTES);
    stringWithin(task.target.description, `${label}.target.description`, MAX_LONG_TEXT_BYTES);
    nullableStringWithin(task.target.app, `${label}.target.app`, MAX_SHORT_TEXT_BYTES);
    nullableStringWithin(task.target.windowTitle, `${label}.target.windowTitle`, MAX_SHORT_TEXT_BYTES);
    stringWithin(task.change.instruction, `${label}.change.instruction`, MAX_LONG_TEXT_BYTES);
    nullableStringWithin(task.change.value, `${label}.change.value`, MAX_SHORT_TEXT_BYTES);
    stringArrayWithin(task.constraints, `${label}.constraints`);
    stringArrayWithin(task.acceptanceCriteria, `${label}.acceptanceCriteria`);
    stringArrayWithin(task.assumptions, `${label}.assumptions`);
    if (task.evidence.length > MAX_ITEMS_PER_ARRAY) throw new Error(`${label}.evidence has too many items`);

    const region = task.target.region;
    if (region) {
      if (region.width <= 0 || region.height <= 0
        || region.x < 0 || region.y < 0
        || region.x + region.width > 1 + Number.EPSILON
        || region.y + region.height > 1 + Number.EPSILON) {
        throw new Error(`${label}.target.region must be nonzero and within normalized bounds`);
      }
    }

    for (const [evidenceIndex, evidence] of task.evidence.entries()) {
      validateEvidence(evidence, `${label}.evidence[${evidenceIndex}]`, context);
    }
  }
}

function validateEvidence(evidence: Evidence, label: string, context: TaskSpecSemanticContext): void {
  if (!Number.isInteger(evidence.tMs) || evidence.tMs < 0 || evidence.tMs > context.durationMs) {
    throw new Error(`${label}.tMs is outside the session timeline`);
  }
  nullableStringWithin(evidence.quote, `${label}.quote`, MAX_EVIDENCE_QUOTE_BYTES);
  nullableStringWithin(evidence.frame, `${label}.frame`, 512);
  if (evidence.frame && !context.allowedFrames.has(evidence.frame)) {
    throw new Error(`${label}.frame does not come from a selected evidence frame`);
  }
  switch (evidence.kind) {
    case "speech":
      if (!evidence.quote?.trim()) throw new Error(`${label} speech evidence requires a quote`);
      break;
    case "click":
      if (!evidence.position) throw new Error(`${label} click evidence requires a position`);
      break;
    case "frame":
      if (!evidence.frame) throw new Error(`${label} frame evidence requires an allowed frame`);
      break;
  }
}

function stringArrayWithin(values: string[], label: string): void {
  if (values.length > MAX_ITEMS_PER_ARRAY) throw new Error(`${label} has too many items`);
  values.forEach((value, index) => stringWithin(value, `${label}[${index}]`, MAX_LONG_TEXT_BYTES));
}

function nullableStringWithin(value: string | null, label: string, maximumBytes: number): void {
  if (value !== null) stringWithin(value, label, maximumBytes);
}

function stringWithin(value: string, label: string, maximumBytes: number): void {
  if (encoder.encode(value).byteLength > maximumBytes) throw new Error(`${label} exceeds its size limit`);
}
