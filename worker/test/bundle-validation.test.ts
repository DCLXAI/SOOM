import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, symlink, truncate } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadValidatedManifest, loadValidatedSessionBundle } from "../src/bundle-validation";
import { fixtureManifest } from "./fixtures";

const temporaryPaths: string[] = [];
afterEach(async () => {
  await Promise.all(temporaryPaths.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("untrusted session bundle validation", () => {
  test("accepts a regular bounded bundle and verifies JPEG dimensions", async () => {
    const session = await validBundle();
    const bundle = await loadValidatedSessionBundle(await loadValidatedManifest(session));
    expect(bundle.candidates).toHaveLength(1);
    expect(bundle.framePaths.get("frames/001.jpg")).toContain("/frames/001.jpg");
  });

  test("rejects symlinked frames even when their target is inside the session", async () => {
    const session = await validBundle(false);
    await Bun.write(join(session, "actual.jpg"), minimalJPEG(32, 16));
    await symlink(join(session, "actual.jpg"), join(session, "frames/001.jpg"));
    await expect(loadValidatedSessionBundle(await loadValidatedManifest(session)))
      .rejects.toThrow("symbolic link");
  });

  test("rejects malformed event schemas and non-JPEG evidence", async () => {
    const malformedEvents = await validBundle();
    await Bun.write(join(malformedEvents, "events.ndjson"), JSON.stringify({ sequence: 1, kind: "keyDown" }));
    await expect(loadValidatedSessionBundle(await loadValidatedManifest(malformedEvents)))
      .rejects.toThrow("schema validation");

    const badJPEG = await validBundle();
    await Bun.write(join(badJPEG, "frames/001.jpg"), "not-an-image");
    await expect(loadValidatedSessionBundle(await loadValidatedManifest(badJPEG)))
      .rejects.toThrow("not a JPEG");
  });

  test("rejects audio larger than the 25 MB API boundary", async () => {
    const session = await validBundle();
    await truncate(join(session, "microphone.m4a"), 25 * 1024 * 1024 + 1);
    await expect(loadValidatedSessionBundle(await loadValidatedManifest(session)))
      .rejects.toThrow("25 MB limit");
  });
});

async function validBundle(writeFrame = true): Promise<string> {
  const session = await mkdtemp(join(tmpdir(), "soom-bundle-validation-"));
  temporaryPaths.push(session);
  await mkdir(join(session, "frames"), { recursive: true });
  await Bun.write(join(session, "session.json"), JSON.stringify(fixtureManifest()));
  await Bun.write(join(session, "microphone.m4a"), "fixture-audio");
  await Bun.write(join(session, "events.ndjson"), "");
  await Bun.write(join(session, "frames/index.json"), JSON.stringify([
    { file: "frames/001.jpg", tMs: 100, kind: "first" },
  ]));
  if (writeFrame) await Bun.write(join(session, "frames/001.jpg"), minimalJPEG(32, 16));
  return session;
}

function minimalJPEG(width: number, height: number): Uint8Array {
  return Uint8Array.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    0xff, 0xd9,
  ]);
}
