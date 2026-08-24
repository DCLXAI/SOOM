import { jsonBody } from "@/lib/http";
import { platform } from "@/lib/platform";
import { requireUploadAuthorization } from "@/lib/security";
import { videoById } from "@/lib/database";
import { makeWebVtt, transcriptWords } from "@/lib/captions";

type MetadataBody = { transcript?: unknown; taskSpec?: unknown; durationMs?: number };

export async function PUT(request: Request, context: { params: Promise<{ uploadId: string }> }) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  const { uploadId } = await context.params;
  const video = await videoById(uploadId);
  if (!video) return Response.json({ error: "Upload not found" }, { status: 404 });
  const body = await jsonBody<MetadataBody>(request);
  const transcript = body.transcript === undefined ? null : JSON.stringify(body.transcript);
  const taskSpec = body.taskSpec === undefined ? null : JSON.stringify(body.taskSpec);
  if ((transcript?.length ?? 0) > 2_000_000 || (taskSpec?.length ?? 0) > 1_000_000) {
    return Response.json({ error: "Metadata is too large" }, { status: 413 });
  }
  const words = transcriptWords(body.transcript);
  const captionsKey = words.length ? `videos/${video.id}/processed/captions.vtt` : null;
  if (captionsKey) {
    await platform().MEDIA.put(captionsKey, makeWebVtt(words), {
      httpMetadata: { contentType: "text/vtt; charset=utf-8" },
    });
  }
  await platform().DB.prepare(
    `UPDATE videos SET transcript_json = COALESCE(?, transcript_json), taskspec_json = COALESCE(?, taskspec_json),
     captions_key = COALESCE(?, captions_key), duration_ms = COALESCE(?, duration_ms), updated_at = ? WHERE id = ?`,
  ).bind(transcript, taskSpec, captionsKey, body.durationMs ? Math.round(body.durationMs) : null, Date.now(), uploadId).run();
  return Response.json({ ok: true });
}
