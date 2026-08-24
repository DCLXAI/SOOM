import { videoById } from "@/lib/database";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";

export async function PUT(request: Request, context: { params: Promise<{ uploadId: string; partNumber: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  const { uploadId, partNumber: rawPartNumber } = await context.params;
  const partNumber = Number(rawPartNumber);
  if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10_000 || !request.body) {
    return Response.json({ error: "Invalid multipart chunk" }, { status: 400 });
  }
  const video = await videoById(uploadId);
  if (!video || video.status !== "uploading") return Response.json({ error: "Active upload not found" }, { status: 404 });
  try {
    const sizeBytes = Number(request.headers.get("content-length") ?? 0);
    const multipart = platform().MEDIA.resumeMultipartUpload(video.source_key, video.upload_id);
    const part = await multipart.uploadPart(partNumber, request.body);
    const now = Date.now();
    await platform().DB.batch([
      platform().DB.prepare(
        `INSERT INTO upload_parts (video_id, part_number, etag, size_bytes, created_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(video_id, part_number) DO UPDATE SET etag = excluded.etag, size_bytes = excluded.size_bytes`,
      ).bind(uploadId, partNumber, part.etag, sizeBytes, now),
      platform().DB.prepare(
        `UPDATE videos SET received_bytes = (
          SELECT COALESCE(SUM(size_bytes), 0) FROM upload_parts WHERE video_id = ?
        ), updated_at = ? WHERE id = ?`,
      ).bind(uploadId, now, uploadId),
    ]);
    return Response.json({ partNumber, etag: part.etag, sizeBytes });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Chunk upload failed" }, { status: 500 });
  }
}
