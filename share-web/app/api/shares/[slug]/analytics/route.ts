import { platform } from "@/lib/platform";
import { authorizeShare } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

export async function GET(request: Request, context: { params: Promise<{ slug: string }> }) {
  const { slug } = await context.params;
  const video = await videoBySlug(slug);
  if (!video || await authorizeShare(request, video) !== "owner") return Response.json({ error: "Owner access required" }, { status: 403 });
  const summary = await platform().DB.prepare(
    `SELECT
      COUNT(DISTINCT viewer_hash) AS uniqueViewers,
      SUM(CASE WHEN event = 'open' THEN 1 ELSE 0 END) AS opens,
      SUM(CASE WHEN event = 'complete' THEN 1 ELSE 0 END) AS completions,
      MAX(watched_ms) AS longestWatchMs,
      AVG(CASE WHEN event IN ('heartbeat', 'complete') THEN watched_ms END) AS averageWatchMs
     FROM view_events WHERE video_id = ?`,
  ).bind(video.id).first();
  const sources = await platform().DB.prepare(
    `SELECT COALESCE(referrer_host, 'direct') AS source, COUNT(*) AS events
     FROM view_events WHERE video_id = ? GROUP BY referrer_host ORDER BY events DESC LIMIT 10`,
  ).bind(video.id).all();
  return Response.json({ summary, sources: sources.results });
}
