import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("metadata route regenerates WebVTT after a transcode race", async () => {
  const [route, captions] = await Promise.all([
    readFile(new URL("../app/api/uploads/[uploadId]/metadata/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/captions.ts", import.meta.url), "utf8"),
  ]);
  assert.match(route, /makeWebVtt/);
  assert.match(route, /captions_key = COALESCE/);
  assert.match(route, /text\/vtt/);
  assert.match(captions, /WEBVTT/);
  assert.match(captions, /group\.at\(-1\)/);
});
