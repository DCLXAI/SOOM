import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render(path = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request(`http://localhost${path}`, { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the finished SOOM share experience", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  const html = await response.text();
  assert.match(html, /SOOM/);
  assert.match(html, /랜딩 페이지 hero와 모바일 카드 수정/);
  assert.match(html, /AI INTENT COMPILER/);
  assert.match(html, /Hero 높이 축소/);
  assert.match(html, /공유 링크 복사/);
  assert.doesNotMatch(html, /codex-preview|react-loading-skeleton|Your site is taking shape/i);
});

test("declares durable video storage and removes starter artifacts", async () => {
  const [hosting, packageJson, layout, page] = await Promise.all([
    readFile(new URL("../.openai/hosting.json", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
  ]);
  const hostingConfig = JSON.parse(hosting);
  assert.equal(hostingConfig.d1, "DB");
  assert.equal(hostingConfig.r2, "MEDIA");
  assert.match(hostingConfig.project_id, /^appgprj_/);
  assert.doesNotMatch(packageJson, /react-loading-skeleton/);
  assert.match(layout, /\/og\.png/);
  assert.match(layout, /summary_large_image/);
  assert.match(page, /ShareExperience/);
  await assert.rejects(access(new URL("../app/_sites-preview", import.meta.url)));
  await access(new URL("../public/og.png", import.meta.url));
  await access(new URL("../drizzle/0000_tearful_liz_osborn.sql", import.meta.url));
});
