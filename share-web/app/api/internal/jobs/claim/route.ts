import { ensureDatabase, videoById } from "@/lib/database";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

export async function POST(request: Request) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  await ensureDatabase();
  const workerId = request.headers.get("x-soom-worker")?.slice(0, 120) || crypto.randomUUID();
  const now = Date.now();
  await platform().DB.prepare(
    "UPDATE processing_jobs SET status = 'pending', worker_id = NULL, lease_until = NULL WHERE status = 'processing' AND lease_until < ?",
  ).bind(now).run();
  const candidate = await platform().DB.prepare(
    "SELECT id, video_id AS videoId FROM processing_jobs WHERE status = 'pending' AND attempts < 4 ORDER BY created_at LIMIT 1",
  ).first<{ id: string; videoId: string }>();
  if (!candidate) return new Response(null, { status: 204 });
  const leaseUntil = now + 15 * 60_000;
  const result = await platform().DB.prepare(
    `UPDATE processing_jobs SET status = 'processing', worker_id = ?, lease_until = ?, attempts = attempts + 1, updated_at = ?
     WHERE id = ? AND status = 'pending'`,
  ).bind(workerId, leaseUntil, now, candidate.id).run();
  if (!result.meta.changes) return new Response(null, { status: 409 });
  const video = await videoById(candidate.videoId);
  if (!video) return Response.json({ error: "Video missing" }, { status: 500 });
  return Response.json({
    jobId: candidate.id,
    videoId: video.id,
    durationMs: video.duration_ms,
    sourceURL: `/api/internal/jobs/${candidate.id}/source`,
    assetURL: `/api/internal/jobs/${candidate.id}/assets`,
    transcript: video.transcript_json ? JSON.parse(video.transcript_json) : null,
  });
}
