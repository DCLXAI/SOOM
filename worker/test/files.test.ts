import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, utimes } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { cleanupStaleExportDirectories } from "../src/files";

const temporaryPaths: string[] = [];
afterEach(async () => {
  await Promise.all(temporaryPaths.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("atomic export staging cleanup", () => {
  test("removes only stale SOOM staging directories", async () => {
    const root = await mkdtemp(join(tmpdir(), "soom-export-cleanup-"));
    temporaryPaths.push(root);
    const stale = join(root, ".soom-00000000-0000-4000-8000-000000000000.tmp");
    const recent = join(root, ".soom-11111111-1111-4111-8111-111111111111.tmp");
    const unrelated = join(root, ".soom-user-data.tmp");
    await Promise.all([stale, recent, unrelated].map((path) => mkdir(path)));
    await utimes(stale, new Date(0), new Date(0));

    await cleanupStaleExportDirectories(root, 1_000, 10_000);

    expect(await Bun.file(stale).exists()).toBe(false);
    expect((await import("node:fs/promises")).stat(recent)).resolves.toBeDefined();
    expect((await import("node:fs/promises")).stat(unrelated)).resolves.toBeDefined();
  });
});
