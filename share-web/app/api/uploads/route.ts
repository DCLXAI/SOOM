import { ensureDatabase } from "@/lib/database";
import { jsonBody, requestOrigin } from "@/lib/http";
import { platform } from "@/lib/platform";
import { passwordDigest, randomToken, requireUploadAuthorization, sha256 } from "@/lib/security";

type CreateUploadBody = {
  sessionId: string;
  title?: string;
  totalBytes: number;
  mimeType?: string;
  privacy?: "private" | "public" | "password";
  password?: string;
  expiresAt?: string | null;
  allowDownload?: boolean;
};

export async function POST(request: Request) {
  const denied = await requireUploadAuthorization(request);
  if (denied) return denied;
  await ensureDatabase();

  try {
    const body = await jsonBody<CreateUploadBody>(request);
    if (!body.sessionId || !Number.isFinite(body.totalBytes) || body.totalBytes <= 0) {
      return Response.json({ error: "sessionId and positive totalBytes are required" }, { status: 400 });
    }
    const privacy = body.privacy ?? "private";
    if (privacy === "password" && (!body.password || body.password.length < 4)) {
      return Response.json({ error: "Password must contain at least 4 characters" }, { status: 400 });
    }
    const id = crypto.randomUUID();
    const slug = randomToken(9);
    const ownerToken = randomToken(24);
    const passwordSalt = privacy === "password" ? randomToken(16) : null;
    const passwordHash = passwordSalt && body.password ? await passwordDigest(body.password, passwordSalt) : null;
    const sourceKey = `videos/${id}/source.mp4`;
    const multipart = await platform().MEDIA.createMultipartUpload(sourceKey, {
      httpMetadata: { contentType: body.mimeType ?? "video/mp4" },
      customMetadata: { sessionId: body.sessionId },
    });
    const now = Date.now();
    const expiresAt = body.expiresAt ? Date.parse(body.expiresAt) : null;
    await platform().DB.prepare(
      `INSERT INTO videos (
        id, slug, title, status, privacy, password_salt, password_hash, owner_token_hash,
        expires_at, allow_download, source_key, upload_id, total_bytes, received_bytes,
        mime_type, created_at, updated_at
      ) VALUES (?, ?, ?, 'uploading', ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)`,
    ).bind(
      id,
      slug,
      (body.title?.trim() || `SOOM 녹화 ${new Date(now).toLocaleDateString("ko-KR")}`).slice(0, 120),
      privacy,
      passwordSalt,
      passwordHash,
      await sha256(ownerToken),
      Number.isFinite(expiresAt) ? expiresAt : null,
      body.allowDownload ? 1 : 0,
      sourceKey,
      multipart.uploadId,
      Math.round(body.totalBytes),
      body.mimeType ?? "video/mp4",
      now,
      now,
    ).run();

    const shareURL = `${requestOrigin(request)}/s/${slug}?token=${encodeURIComponent(ownerToken)}`;
    return Response.json({
      uploadId: id,
      chunkSize: 8 * 1024 * 1024,
      uploadedParts: [],
      ownerToken,
      shareURL,
      privacy,
    }, { status: 201 });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Could not create upload" }, { status: 500 });
  }
}
