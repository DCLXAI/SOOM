import { clampInteger, jsonBody } from "@/lib/http";
import { platform } from "@/lib/platform";
import { authorizeShare } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

export async function POST(request: Request, context: { params: Promise<{ slug: string }> }) {
  const { slug } = await context.params;
  const video = await videoBySlug(slug);
  if (!video || !await authorizeShare(request, video)) return Response.json({ error: "Unauthorized" }, { status: 401 });
  const body = await jsonBody<{ displayName?: string; body?: string; tMs?: number }>(request);
  const message = body.body?.trim().slice(0, 2_000) ?? "";
  if (!message) return Response.json({ error: "댓글을 입력해 주세요." }, { status: 400 });
  const comment = {
    id: crypto.randomUUID(),
    displayName: (body.displayName?.trim() || "게스트").slice(0, 48),
    body: message,
    tMs: clampInteger(body.tMs, 0, video.duration_ms ?? 86_400_000),
    createdAt: Date.now(),
  };
  await platform().DB.prepare(
    "INSERT INTO comments (id, video_id, display_name, body, t_ms, created_at) VALUES (?, ?, ?, ?, ?, ?)",
  ).bind(comment.id, video.id, comment.displayName, comment.body, comment.tMs, comment.createdAt).run();
  return Response.json(comment, { status: 201 });
}
