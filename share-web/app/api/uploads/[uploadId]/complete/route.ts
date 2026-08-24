import { videoById } from "@/lib/database";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

export async function POST(request: Request, context: { params: Promise<{ uploadId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  const { uploadId } = await context.params;
  const video = await videoById(uploadId);
  if (!video || video.status !== "uploading") return Response.json({ error: "Active upload not found" }, { status: 404 });
  const result = await platform().DB.prepare(
    "SELECT part_number AS partNumber, etag, size_bytes AS sizeBytes FROM upload_parts WHERE video_id = ? ORDER BY part_number",
  ).bind(uploadId).all<{ partNumber: number; etag: string; sizeBytes: number }>();
  const parts = result.results;
  if (!parts.length || parts.reduce((sum, item) => sum + item.sizeBytes, 0) !== video.total_bytes) {
    return Response.json({ error: "Upload is incomplete", uploadedParts: parts.length }, { status: 409 });
  }
  try {
    await platform().MEDIA.resumeMultipartUpload(video.source_key, video.upload_id).complete(
      parts.map(({ partNumber, etag }) => ({ partNumber, etag })),
    );
    const now = Date.now();
    const jobId = crypto.randomUUID();
    await platform().DB.batch([
      platform().DB.prepare(
        "UPDATE videos SET status = 'processing', playback_key = source_key, received_bytes = total_bytes, updated_at = ? WHERE id = ?",
      ).bind(now, uploadId),
      platform().DB.prepare(
        "INSERT INTO processing_jobs (id, video_id, status, attempts, created_at, updated_at) VALUES (?, ?, 'pending', 0, ?, ?)",
      ).bind(jobId, uploadId, now, now),
    ]);
    return Response.json({ status: "processing", jobId, slug: video.slug });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Could not finalize upload" }, { status: 500 });
  }
}
