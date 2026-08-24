import { safeObjectName } from "@/lib/http";
import { platform } from "@/lib/platform";
import { authorizeShare } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

export async function GET(request: Request, context: { params: Promise<{ slug: string; asset: string[] }> }) {
  const { slug, asset } = await context.params;
  const video = await videoBySlug(slug);
  if (!video || !await authorizeShare(request, video)) return new Response("Unauthorized", { status: 401 });
  const name = asset.map(safeObjectName).join("/");
  if (!name || name.includes("..")) return new Response("Invalid asset", { status: 400 });
  const key = `videos/${video.id}/processed/hls/${name}`;
  const object = await platform().MEDIA.get(key, { range: request.headers });
  if (!object) return new Response("Not found", { status: 404 });
  if (name.endsWith(".m3u8")) {
    const search = new URL(request.url).search;
    const manifest = (await object.text()).split("\n").map((line) => {
      const trimmed = line.trim();
      return search && trimmed && !trimmed.startsWith("#") ? `${trimmed}${search}` : line;
    }).join("\n");
    return new Response(manifest, {
      headers: {
        "content-type": "application/vnd.apple.mpegurl",
        "cache-control": video.privacy === "public" ? "public, max-age=3600" : "private, no-store",
      },
    });
  }
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", video.privacy === "public" ? "public, max-age=3600" : "private, no-store");
  const offset = object.range && "offset" in object.range ? object.range.offset : undefined;
  const length = object.range && "length" in object.range ? object.range.length : undefined;
  if (request.headers.has("range") && typeof offset === "number" && typeof length === "number") {
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { headers });
}
