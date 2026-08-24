import { clampInteger, jsonBody } from "@/lib/http";
import { platform } from "@/lib/platform";
import { authorizeShare, viewerHash } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

const events = new Set(["open", "play", "heartbeat", "complete"]);

export async function POST(request: Request, context: { params: Promise<{ slug: string }> }) {
  const { slug } = await context.params;
  const video = await videoBySlug(slug);
  if (!video || !await authorizeShare(request, video)) return new Response(null, { status: 204 });
  const body = await jsonBody<{ event?: string; tMs?: number; watchedMs?: number; referrer?: string }>(request);
  if (!body.event || !events.has(body.event)) return Response.json({ error: "Invalid event" }, { status: 400 });
  let referrerHost: string | null = null;
  try { referrerHost = body.referrer ? new URL(body.referrer).host.slice(0, 160) : null; } catch { referrerHost = null; }
  await platform().DB.prepare(
    `INSERT INTO view_events (id, video_id, viewer_hash, event, t_ms, watched_ms, referrer_host, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    crypto.randomUUID(), video.id, await viewerHash(request), body.event,
    clampInteger(body.tMs, 0, video.duration_ms ?? 86_400_000),
    clampInteger(body.watchedMs, 0, video.duration_ms ?? 86_400_000),
    referrerHost, Date.now(),
  ).run();
  return new Response(null, { status: 204 });
}
