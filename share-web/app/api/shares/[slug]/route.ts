import { platform } from "@/lib/platform";
import { authorizeShare } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

export async function GET(request: Request, context: { params: Promise<{ slug: string }> }) {
  const { slug } = await context.params;
  const video = await videoBySlug(slug);
  if (!video) return Response.json({ error: "Recording not found" }, { status: 404 });
  if (video.expires_at && video.expires_at <= Date.now()) {
    return Response.json({ error: "This link has expired", expired: true }, { status: 410 });
  }
  const access = await authorizeShare(request, video);
  if (!access) {
    return Response.json({
      locked: true,
      privacy: video.privacy,
      requiresPassword: video.privacy === "password",
      title: video.title,
    }, { status: 401 });
  }
  const [commentRows, reactionRows] = await Promise.all([
    platform().DB.prepare(
      "SELECT id, display_name AS displayName, body, t_ms AS tMs, created_at AS createdAt FROM comments WHERE video_id = ? ORDER BY created_at",
    ).bind(video.id).all(),
    platform().DB.prepare(
      "SELECT emoji, t_ms AS tMs, COUNT(*) AS count FROM reactions WHERE video_id = ? GROUP BY emoji, t_ms ORDER BY t_ms",
    ).bind(video.id).all(),
  ]);
  const transcript = video.transcript_json ? JSON.parse(video.transcript_json) : { text: "", words: [] };
  const taskSpec = video.taskspec_json ? JSON.parse(video.taskspec_json) : null;
  return Response.json({
    id: video.id,
    slug: video.slug,
    title: video.title,
    status: video.status,
    privacy: video.privacy,
    expiresAt: video.expires_at,
    isOwner: access === "owner",
    allowDownload: Boolean(video.allow_download),
    durationMs: video.duration_ms,
    createdAt: video.created_at,
    playbackURL: `/api/media/${slug}/video${new URL(request.url).search}`,
    hlsURL: video.hls_manifest_key ? `/api/media/${slug}/hls/index.m3u8${new URL(request.url).search}` : null,
    captionsURL: video.captions_key ? `/api/media/${slug}/captions${new URL(request.url).search}` : null,
    thumbnailURL: video.thumbnail_key ? `/api/media/${slug}/thumbnail${new URL(request.url).search}` : null,
    waveformURL: video.waveform_key ? `/api/media/${slug}/waveform${new URL(request.url).search}` : null,
    downloadURL: video.allow_download ? `/api/media/${slug}/download${new URL(request.url).search}` : null,
    transcript,
    taskSpec,
    comments: commentRows.results,
    reactions: reactionRows.results,
  });
}
