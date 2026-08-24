import { ensureDatabase } from "@/lib/database";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

export async function GET(request: Request, context: { params: Promise<{ jobId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  await ensureDatabase();
  const { jobId } = await context.params;
  const row = await platform().DB.prepare(
    `SELECT v.source_key AS sourceKey FROM processing_jobs j JOIN videos v ON v.id = j.video_id
     WHERE j.id = ? AND j.status = 'processing' LIMIT 1`,
  ).bind(jobId).first<{ sourceKey: string }>();
  if (!row) return new Response("Job not found", { status: 404 });
  const object = await platform().MEDIA.get(row.sourceKey);
  if (!object) return new Response("Source missing", { status: 404 });
  const headers = new Headers({ "content-type": "video/mp4", "content-length": String(object.size), etag: object.httpEtag });
  return new Response(object.body, { headers });
}
