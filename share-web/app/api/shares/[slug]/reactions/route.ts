import { clampInteger, jsonBody } from "@/lib/http";
import { platform } from "@/lib/platform";
import { authorizeShare, viewerHash } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

const allowedEmoji = new Set(["👍", "❤️", "🎉", "😂", "👀"]);

export async function POST(request: Request, context: { params: Promise<{ slug: string }> }) {
  const { slug } = await context.params;
  const video = await videoBySlug(slug);
  if (!video || !await authorizeShare(request, video)) return Response.json({ error: "Unauthorized" }, { status: 401 });
  const body = await jsonBody<{ emoji?: string; tMs?: number }>(request);
  if (!body.emoji || !allowedEmoji.has(body.emoji)) return Response.json({ error: "Unsupported reaction" }, { status: 400 });
  const tMs = Math.round(clampInteger(body.tMs, 0, video.duration_ms ?? 86_400_000) / 1_000) * 1_000;
  await platform().DB.prepare(
    `INSERT OR IGNORE INTO reactions (id, video_id, emoji, t_ms, viewer_hash, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).bind(crypto.randomUUID(), video.id, body.emoji, tMs, await viewerHash(request), Date.now()).run();
  return Response.json({ ok: true, emoji: body.emoji, tMs }, { status: 201 });
}
