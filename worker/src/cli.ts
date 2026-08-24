#!/usr/bin/env bun
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { parseCLIArguments } from "./cli-arguments";
import { OpenAIClient } from "./openai-client";
import { processSession } from "./process";
import { statusOf } from "./retry";
import type { ProgressEvent } from "./types";

function emit(event: ProgressEvent) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

async function main() {
  // Bun source execution uses [bun, script, ...args], while a compiled helper
  // uses [executable, ...args]. Only those two exact layouts are accepted so
  // stray positional arguments cannot be ignored before the command.
  const commandIndex = Bun.argv[1] === "process" ? 1 : 2;
  const arguments_ = parseCLIArguments(Bun.argv.slice(commandIndex));
  const apiKey = await readAPIKey();
  if (!apiKey) throw Object.assign(new Error("OpenAI API key is missing"), { status: 401 });

  const sessionPath = resolve(arguments_.sessionPath);
  const outputPath = resolve(arguments_.exportPath);
  await mkdir(outputPath, { recursive: true, mode: 0o700 });
  await processSession({
    sessionPath,
    exportPath: outputPath,
    client: new OpenAIClient(apiKey),
    emit,
  });
}

async function readAPIKey(): Promise<string | undefined> {
  if (process.env.SOOM_API_KEY_STDIN === "1") {
    // The packaged app passes BYOK over an inherited pipe so the secret is not
    // visible in argv or the child environment. Keep the payload deliberately
    // tiny and reject unexpected protocol data.
    const key = (await Bun.stdin.text()).trim();
    if (key.length === 0 || key.length > 512 || key.includes("\0")) return undefined;
    return key;
  }
  // Direct CLI use remains convenient for contributors and CI fixtures.
  return process.env.OPENAI_API_KEY?.trim() || undefined;
}

try {
  await main();
} catch (error) {
  const status = statusOf(error);
  const message = publicErrorMessage(error, status);
  emit({ type: "error", stage: "processing", message });
  process.stderr.write(`${JSON.stringify({ stage: "processing", status: status ?? null, error: message })}\n`);
  process.exit(1);
}

function publicErrorMessage(error: unknown, status?: number): string {
  if (error instanceof Error && /CLI flag|--session|--export|Usage:/.test(error.message)) return error.message;
  if (status === 401 || status === 403) return "OpenAI API 키 또는 권한을 확인해 주세요.";
  if (status === 429) return "OpenAI 요청 한도를 초과했습니다. 잠시 후 다시 시도해 주세요.";
  if (status !== undefined && status >= 500) return "OpenAI 서비스가 일시적으로 응답하지 않습니다.";
  if (error instanceof SyntaxError) return "AI 응답을 JSON으로 읽을 수 없습니다.";
  if (error instanceof Error && /schema validation/i.test(error.message)) return "AI 응답이 TaskSpec 스키마와 맞지 않습니다.";
  if (error instanceof Error && /missing|unavailable|permission|EACCES|ENOENT/i.test(error.message)) return error.message;
  return "TaskSpec 처리 중 오류가 발생했습니다. 세션은 보존되었습니다.";
}
