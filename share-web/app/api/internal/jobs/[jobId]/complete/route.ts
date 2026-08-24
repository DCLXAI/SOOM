import { ensureDatabase } from "@/lib/database";
import { jsonBody, safeObjectName } from "@/lib/http";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

type CompleteBody = {
  playback: string;
  hls: string;
  thumbnail: string;
  waveform: string;
  captions?: string | null;
  durationMs?: number;
};

export async function POST(request: Request, context: { params: Promise<{ jobId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  await ensureDatabase();
  const { jobId } = await context.params;
  const row = await platform().DB.prepare(
    "SELECT video_id AS videoId FROM processing_jobs WHERE id = ? AND status = 'processing' LIMIT 1",
  ).bind(jobId).first<{ videoId: string }>();
  if (!row) return Response.json({ error: "Job not found" }, { status: 404 });
  const body = await jsonBody<CompleteBody>(request);
  const names = [body.playback, body.hls, body.thumbnail, body.waveform, body.captions].filter(Boolean) as string[];
  if (names.some((name) => safeObjectName(name) !== name || name.includes(".."))) {
    return Response.json({ error: "Invalid processed asset" }, { status: 400 });
  }
  const key = (name: string | null | undefined) => name ? `videos/${row.videoId}/processed/${name}` : null;
  const now = Date.now();
  await platform().DB.batch([
    platform().DB.prepare(
      `UPDATE videos SET status = 'ready', playback_key = ?, hls_manifest_key = ?, thumbnail_key = ?,
       waveform_key = ?, captions_key = ?, duration_ms = COALESCE(?, duration_ms), updated_at = ? WHERE id = ?`,
    ).bind(key(body.playback), key(body.hls), key(body.thumbnail), key(body.waveform), key(body.captions), body.durationMs ?? null, now, row.videoId),
    platform().DB.prepare(
      "UPDATE processing_jobs SET status = 'completed', lease_until = NULL, updated_at = ? WHERE id = ?",
    ).bind(now, jobId),
  ]);
  return Response.json({ ok: true });
}
