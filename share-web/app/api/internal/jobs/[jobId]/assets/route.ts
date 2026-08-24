import { ensureDatabase } from "@/lib/database";
import { safeObjectName } from "@/lib/http";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

const allowedTypes: Record<string, string> = {
  mp4: "video/mp4",
  m3u8: "application/vnd.apple.mpegurl",
  ts: "video/mp2t",
  jpg: "image/jpeg",
  png: "image/png",
  vtt: "text/vtt; charset=utf-8",
};

export async function PUT(request: Request, context: { params: Promise<{ jobId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  if (!request.body) return Response.json({ error: "Asset body required" }, { status: 400 });
  await ensureDatabase();
  const { jobId } = await context.params;
  const row = await platform().DB.prepare(
    `SELECT v.id AS videoId FROM processing_jobs j JOIN videos v ON v.id = j.video_id
     WHERE j.id = ? AND j.status = 'processing' LIMIT 1`,
  ).bind(jobId).first<{ videoId: string }>();
  if (!row) return Response.json({ error: "Job not found" }, { status: 404 });
  const rawName = new URL(request.url).searchParams.get("name") ?? "";
  const name = safeObjectName(rawName).replace(/^\/+/, "");
  const extension = name.split(".").pop()?.toLowerCase() ?? "";
  if (!name || name.includes("..") || !allowedTypes[extension]) return Response.json({ error: "Unsupported asset name" }, { status: 400 });
  const key = `videos/${row.videoId}/processed/${name}`;
  await platform().MEDIA.put(key, request.body, { httpMetadata: { contentType: allowedTypes[extension] } });
  return Response.json({ key });
}
