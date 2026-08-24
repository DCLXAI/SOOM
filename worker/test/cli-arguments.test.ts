import { describe, expect, test } from "bun:test";
import { parseCLIArguments } from "../src/cli-arguments";

describe("strict CLI arguments", () => {
  test("accepts exactly one session and export flag in either order", () => {
    expect(parseCLIArguments(["process", "--session", "/tmp/session", "--export", "/tmp/out"]))
      .toEqual({ command: "process", sessionPath: "/tmp/session", exportPath: "/tmp/out" });
    expect(parseCLIArguments(["process", "--export", "/tmp/out", "--session", "/tmp/session"]).sessionPath)
      .toBe("/tmp/session");
  });

  test("rejects unknown, duplicate, positional, and missing flags", () => {
    expect(() => parseCLIArguments(["process", "--session", "a", "--unknown", "b"])).toThrow("Unknown");
    expect(() => parseCLIArguments(["process", "--session", "a", "--session", "b"])).toThrow("Duplicate");
    expect(() => parseCLIArguments(["process", "--session", "a", "--export", "b", "extra"])).toThrow();
    expect(() => parseCLIArguments(["process", "--session", "a", "--export"])).toThrow();
  });
});
