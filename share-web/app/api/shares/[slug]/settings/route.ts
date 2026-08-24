import { jsonBody } from "@/lib/http";
import { platform } from "@/lib/platform";
import { authorizeShare, passwordDigest, randomToken } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

export async function PATCH(request: Request, context: { params: Promise<{ slug: string }> }) {
  const { slug } = await context.params;
  const video = await videoBySlug(slug);
  if (!video || await authorizeShare(request, video) !== "owner") return Response.json({ error: "Owner access required" }, { status: 403 });
  const body = await jsonBody<{
    privacy?: "private" | "public" | "password";
    password?: string;
    expiresAt?: string | null;
    allowDownload?: boolean;
    title?: string;
  }>(request);
  const privacy = body.privacy ?? video.privacy;
  const salt = privacy === "password" ? randomToken(16) : null;
  if (privacy === "password" && (!body.password || body.password.length < 4)) {
    return Response.json({ error: "Password must contain at least 4 characters" }, { status: 400 });
  }
  const hash = salt && body.password ? await passwordDigest(body.password, salt) : null;
  const expiresAt = body.expiresAt === undefined ? video.expires_at : body.expiresAt ? Date.parse(body.expiresAt) : null;
  await platform().DB.prepare(
    `UPDATE videos SET title = ?, privacy = ?, password_salt = ?, password_hash = ?, expires_at = ?,
     allow_download = ?, updated_at = ? WHERE id = ?`,
  ).bind(
    (body.title?.trim() || video.title).slice(0, 120), privacy, salt, hash,
    Number.isFinite(expiresAt) ? expiresAt : null,
    body.allowDownload === undefined ? video.allow_download : body.allowDownload ? 1 : 0,
    Date.now(), video.id,
  ).run();
  return Response.json({ ok: true, privacy, expiresAt, allowDownload: body.allowDownload ?? Boolean(video.allow_download) });
}
