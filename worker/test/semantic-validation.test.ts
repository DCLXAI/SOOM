import { describe, expect, test } from "bun:test";
import { validateTaskSpecSemantics } from "../src/semantic-validation";
import { fixtureTaskSpec } from "./fixtures";

const context = { sessionId: "fixture-session", durationMs: 12_000, allowedFrames: new Set<string>() };

describe("TaskSpec semantic validation", () => {
  test("accepts the bounded fixture", () => {
    expect(() => validateTaskSpecSemantics(fixtureTaskSpec(), context)).not.toThrow();
  });

  test("rejects duplicate IDs, out-of-range evidence, and invalid regions", () => {
    const duplicate = fixtureTaskSpec();
    duplicate.tasks.push(structuredClone(duplicate.tasks[0]!));
    expect(() => validateTaskSpecSemantics(duplicate, context)).toThrow("duplicated");

    const late = fixtureTaskSpec();
    late.tasks[0]!.evidence[0]!.tMs = 12_001;
    expect(() => validateTaskSpecSemantics(late, context)).toThrow("outside the session timeline");

    const zeroRegion = fixtureTaskSpec();
    zeroRegion.tasks[0]!.target.region!.width = 0;
    expect(() => validateTaskSpecSemantics(zeroRegion, context)).toThrow("nonzero");
  });

  test("enforces kind-specific payloads and selected-frame provenance", () => {
    const speech = fixtureTaskSpec();
    speech.tasks[0]!.evidence[0]!.quote = null;
    expect(() => validateTaskSpecSemantics(speech, context)).toThrow("requires a quote");

    const frame = fixtureTaskSpec();
    frame.tasks[0]!.evidence[0] = {
      kind: "frame", tMs: 100, frame: "frames/unselected.jpg", quote: null, position: null,
    };
    expect(() => validateTaskSpecSemantics(frame, context)).toThrow("selected evidence frame");

    const click = fixtureTaskSpec();
    click.tasks[0]!.evidence[0] = { kind: "click", tMs: 100, frame: null, quote: null, position: null };
    expect(() => validateTaskSpecSemantics(click, context)).toThrow("requires a position");
  });
});
