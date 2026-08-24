import { describe, expect, test } from "bun:test";
import { safeSessionPath } from "../src/frames";
import { sanitizeEvents } from "../src/privacy";
import type { InputEvent } from "../src/types";

describe("privacy sanitization", () => {
  test("raw printable characters become a count-only interval", () => {
    const canary = "CANARY-password-7391";
    const events: InputEvent[] = [...canary].map((character, index) => ({
      sequence: index,
      tMs: index * 50,
      kind: "keyDown",
      keyCode: index,
      characters: character,
      modifiers: [],
      context: { appName: "Browser" },
    }));
    const sanitized = sanitizeEvents(events);
    const encoded = JSON.stringify(sanitized);
    expect(sanitized).toHaveLength(1);
    expect(sanitized[0]?.kind).toBe("typingActivity");
    expect(sanitized[0]?.keyCount).toBe(canary.length);
    expect(encoded).not.toContain(canary);
    expect(encoded).not.toContain("characters");
  });

  test("safe shortcut is retained without arbitrary key text", () => {
    const sanitized = sanitizeEvents([
      {
        sequence: 1,
        tMs: 100,
        kind: "keyDown",
        keyCode: 8,
        characters: "c",
        modifiers: ["command"],
      },
    ]);
    expect(sanitized[0]?.shortcut).toBe("command+c");
  });

  test("capture-reviewed shortcut labels are preferred without raw character access", () => {
    const sanitized = sanitizeEvents([
      {
        sequence: 1,
        tMs: 100,
        kind: "keyDown",
        shortcut: "command+shift+c",
        modifiers: ["command", "shift"],
      },
    ]);
    expect(sanitized[0]?.shortcut).toBe("command+shift+c");
  });

  test("an unreviewed shortcut payload is treated as count-only typing", () => {
    const shortcutCanary = "option+CANARY-secret-character";
    const sanitized = sanitizeEvents([
      {
        sequence: 1,
        tMs: 100,
        kind: "keyDown",
        shortcut: shortcutCanary,
        modifiers: ["option"],
      },
    ]);
    expect(sanitized[0]?.kind).toBe("typingActivity");
    expect(JSON.stringify(sanitized)).not.toContain(shortcutCanary);
  });

  test("window titles are removed from every sanitized event by default", () => {
    const windowCanary = "CANARY confidential customer document";
    const sanitized = sanitizeEvents([
      {
        sequence: 1,
        tMs: 100,
        kind: "mouseDown",
        context: {
          appName: "Browser",
          bundleIdentifier: "com.example.browser",
          windowTitle: windowCanary,
        },
      },
    ]);

    const encoded = JSON.stringify(sanitized);
    expect(encoded).not.toContain(windowCanary);
    expect(encoded).not.toContain("windowTitle");
    expect(sanitized[0]?.context).toEqual({
      appName: "Browser",
      bundleIdentifier: "com.example.browser",
    });
  });

  test("Option-only printable characters become count-only typing activity", () => {
    const optionCharacterCanary = "ß";
    const sanitized = sanitizeEvents([
      {
        sequence: 1,
        tMs: 100,
        kind: "keyDown",
        keyCode: 1,
        characters: optionCharacterCanary,
        modifiers: ["option"],
      },
    ]);

    const encoded = JSON.stringify(sanitized);
    expect(sanitized).toHaveLength(1);
    expect(sanitized[0]?.kind).toBe("typingActivity");
    expect(sanitized[0]?.keyCount).toBe(1);
    expect(encoded).not.toContain(optionCharacterCanary);
    expect(encoded).not.toContain("shortcut");
  });

  test("session artifact cannot escape its bundle", () => {
    expect(() => safeSessionPath("/tmp/session", "../../etc/passwd")).toThrow();
    expect(safeSessionPath("/tmp/session", "frames/001.jpg")).toBe("/tmp/session/frames/001.jpg");
  });
});
