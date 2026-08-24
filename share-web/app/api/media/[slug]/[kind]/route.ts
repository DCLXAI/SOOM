import { safeObjectName } from "@/lib/http";
import { platform } from "@/lib/platform";
import { authorizeShare } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

export async function GET(request: Request, context: { params: Promise<{ slug: string; kind: string }> }) {
  const { slug, kind } = await context.params;
  const video = await videoBySlug(slug);
  if (!video) return new Response("Not found", { status: 404 });
  const access = await authorizeShare(request, video);
  if (!access) return new Response("Unauthorized", { status: 401 });

  let key: string | null = null;
  if (kind === "video" || kind === "download") key = video.playback_key ?? video.source_key;
  if (kind === "thumbnail") key = video.thumbnail_key;
  if (kind === "waveform") key = video.waveform_key;
  if (kind === "captions") key = video.captions_key;
  if (!key) return new Response("Media is processing", { status: 404, headers: { "Retry-After": "5" } });
  if (kind === "download" && !video.allow_download) return new Response("Downloads are disabled", { status: 403 });

  const object = await platform().MEDIA.get(key, { range: request.headers });
  if (!object) return new Response("Not found", { status: 404 });
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", video.privacy === "public" ? "public, max-age=3600" : "private, no-store");
  if (kind === "download") {
    headers.set("content-disposition", `attachment; filename="${safeObjectName(video.title)}.mp4"`);
  }
  const range = object.range;
  const offset = range && "offset" in range ? range.offset : undefined;
  const length = range && "length" in range ? range.length : undefined;
  if (request.headers.has("range") && typeof offset === "number" && typeof length === "number") {
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { headers });
}
