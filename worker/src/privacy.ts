import type { InputEvent, SanitizedContext, SanitizedEvent } from "./types";

const specialKeys: Record<number, string> = {
  36: "return",
  48: "tab",
  49: "space",
  51: "delete",
  53: "escape",
  115: "home",
  116: "pageUp",
  117: "forwardDelete",
  119: "end",
  121: "pageDown",
  123: "leftArrow",
  124: "rightArrow",
  125: "downArrow",
  126: "upArrow",
};

// Hardware key codes are used for shortcuts so no character payload from the
// event can cross the privacy boundary. The names follow the ANSI layout and
// are only hints for the model; unknown keys remain the non-sensitive "key".
const shortcutKeys: Record<number, string> = {
  0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
  11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
  20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "o",
  32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
};

const safeShortcutModifiers = new Set(["command", "control", "option", "shift", "capsLock", "fn"]);
const safeShortcutKeys = new Set([...Object.values(specialKeys), ...Object.values(shortcutKeys), "key"]);

export interface SanitizationOptions {
  typingIdleMs?: number;
}

export function sanitizeEvents(events: InputEvent[], options: SanitizationOptions = {}): SanitizedEvent[] {
  const typingIdleMs = options.typingIdleMs ?? 700;
  const output: SanitizedEvent[] = [];
  let typingStart: InputEvent | undefined;
  let typingEnd: InputEvent | undefined;
  let keyCount = 0;

  const flushTyping = () => {
    if (!typingStart || !typingEnd) return;
    output.push({
      kind: "typingActivity",
      startMs: typingStart.tMs,
      endMs: typingEnd.tMs,
      keyCount,
      context: sanitizeContext(typingStart.context),
    });
    typingStart = undefined;
    typingEnd = undefined;
    keyCount = 0;
  };

  for (const event of [...events].sort((a, b) => a.sequence - b.sequence)) {
    if (typingEnd && event.tMs - typingEnd.tMs > typingIdleMs) flushTyping();

    switch (event.kind) {
      case "keyDown": {
        const modifiers = event.modifiers ?? [];
        const hasCommandOrControl = modifiers.some((value) => value === "command" || value === "control");
        const special = event.keyCode === undefined ? undefined : specialKeys[event.keyCode];
        const storedShortcut = validatedStoredShortcut(event.shortcut);
        if (storedShortcut) {
          flushTyping();
          output.push({
            kind: "shortcut",
            startMs: event.tMs,
            endMs: event.tMs,
            shortcut: storedShortcut,
            context: sanitizeContext(event.context),
          });
          break;
        }
        // Option-modified printable characters can contain the user's actual
        // text (for example option+s producing a Unicode character). Treat an
        // Option-only printable key as typing, while retaining Option-modified
        // navigation/special keys and Command/Control shortcuts.
        if (hasCommandOrControl || special) {
          flushTyping();
          output.push({
            kind: "shortcut",
            startMs: event.tMs,
            endMs: event.tMs,
            shortcut: [...modifiers, special ?? shortcutKeys[event.keyCode ?? -1] ?? "key"].join("+"),
            context: sanitizeContext(event.context),
          });
        } else {
          typingStart ??= event;
          typingEnd = event;
          keyCount += 1;
        }
        break;
      }
      case "mouseDown":
      case "mouseUp":
      case "mouseDragged":
        flushTyping();
        output.push({
          kind: "pointer",
          startMs: event.tMs,
          endMs: event.tMs,
          pointerKind: event.kind,
          position: event.position?.displayNormalizedTopLeft,
          context: sanitizeContext(event.context),
        });
        break;
      case "scroll":
        flushTyping();
        output.push({
          kind: "scroll",
          startMs: event.tMs,
          endMs: event.tMs,
          position: event.position?.displayNormalizedTopLeft,
          scrollDeltaX: event.scrollDeltaX,
          scrollDeltaY: event.scrollDeltaY,
          context: sanitizeContext(event.context),
        });
        break;
      case "captureGap":
        flushTyping();
        output.push({
          kind: "captureGap",
          startMs: event.tMs,
          endMs: event.tMs,
          context: sanitizeContext(event.context),
          reason: event.reason,
        });
        break;
      case "keyUp":
      case "modifiersChanged":
        break;
    }
  }
  flushTyping();
  return output;
}

function validatedStoredShortcut(value: string | undefined): string | undefined {
  if (!value || value.length > 80) return undefined;
  const parts = value.split("+");
  const key = parts.pop();
  if (!key || !safeShortcutKeys.has(key)) return undefined;
  if (!parts.every((modifier) => safeShortcutModifiers.has(modifier))) return undefined;
  const isControlKey = Object.values(specialKeys).includes(key);
  const hasSafeModifier = parts.includes("command") || parts.includes("control");
  return isControlKey || hasSafeModifier ? [...parts, key].join("+") : undefined;
}

function sanitizeContext(context: InputEvent["context"]): SanitizedContext | undefined {
  if (!context) return undefined;
  const sanitized: SanitizedContext = {
    ...(context.appName ? { appName: context.appName } : {}),
    ...(context.bundleIdentifier ? { bundleIdentifier: context.bundleIdentifier } : {}),
  };
  return Object.keys(sanitized).length > 0 ? sanitized : undefined;
}
