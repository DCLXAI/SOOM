import { jsonBody } from "@/lib/http";
import { createAccessToken, passwordDigest } from "@/lib/security";
import { videoBySlug } from "@/lib/database";

export async function POST(request: Request, context: { params: Promise<{ slug: string }> }) {
  const { slug } = await context.params;
  const video = await videoBySlug(slug);
  if (!video || video.privacy !== "password" || !video.password_salt || !video.password_hash) {
    return Response.json({ error: "Password access is unavailable" }, { status: 404 });
  }
  const { password } = await jsonBody<{ password?: string }>(request);
  if (!password || await passwordDigest(password, video.password_salt) !== video.password_hash) {
    return Response.json({ error: "비밀번호가 맞지 않습니다." }, { status: 401 });
  }
  const accessToken = await createAccessToken(slug);
  return Response.json({ ok: true }, {
    headers: {
      "Set-Cookie": `soom_${slug}=${encodeURIComponent(accessToken)}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=86400`,
    },
  });
}
