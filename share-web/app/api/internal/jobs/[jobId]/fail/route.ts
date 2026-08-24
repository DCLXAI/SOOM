import { ensureDatabase } from "@/lib/database";
import { jsonBody } from "@/lib/http";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

export async function POST(request: Request, context: { params: Promise<{ jobId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  await ensureDatabase();
  const { jobId } = await context.params;
  const { error } = await jsonBody<{ error?: string }>(request);
  const now = Date.now();
  await platform().DB.prepare(
    `UPDATE processing_jobs SET status = CASE WHEN attempts >= 4 THEN 'failed' ELSE 'pending' END,
     error = ?, lease_until = NULL, worker_id = NULL, updated_at = ? WHERE id = ?`,
  ).bind((error ?? "Transcode failed").slice(0, 1_000), now, jobId).run();
  await platform().DB.prepare(
    `UPDATE videos SET status = CASE WHEN EXISTS(
      SELECT 1 FROM processing_jobs WHERE id = ? AND status = 'failed'
    ) THEN 'failed' ELSE status END, updated_at = ? WHERE id = (
      SELECT video_id FROM processing_jobs WHERE id = ?
    )`,
  ).bind(jobId, now, jobId).run();
  return Response.json({ ok: true });
}
