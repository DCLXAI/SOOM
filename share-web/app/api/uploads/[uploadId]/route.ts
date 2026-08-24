import { ensureDatabase, videoById } from "@/lib/database";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

export async function GET(request: Request, context: { params: Promise<{ uploadId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  await ensureDatabase();
  const { uploadId } = await context.params;
  const video = await videoById(uploadId);
  if (!video) return Response.json({ error: "Upload not found" }, { status: 404 });
  const parts = await platform().DB.prepare(
    "SELECT part_number AS partNumber, etag, size_bytes AS sizeBytes FROM upload_parts WHERE video_id = ? ORDER BY part_number",
  ).bind(uploadId).all();
  return Response.json({
    uploadId,
    status: video.status,
    receivedBytes: video.received_bytes,
    totalBytes: video.total_bytes,
    uploadedParts: parts.results,
  });
}

export async function DELETE(request: Request, context: { params: Promise<{ uploadId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  const { uploadId } = await context.params;
  const video = await videoById(uploadId);
  if (!video) return Response.json({ error: "Upload not found" }, { status: 404 });
  if (video.status === "uploading") {
    await platform().MEDIA.resumeMultipartUpload(video.source_key, video.upload_id).abort();
  }
  await platform().DB.batch([
    platform().DB.prepare("DELETE FROM upload_parts WHERE video_id = ?").bind(uploadId),
    platform().DB.prepare("DELETE FROM processing_jobs WHERE video_id = ?").bind(uploadId),
    platform().DB.prepare("DELETE FROM videos WHERE id = ?").bind(uploadId),
  ]);
  return new Response(null, { status: 204 });
}
