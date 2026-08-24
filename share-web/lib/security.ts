import { platform } from "./platform";
import type { VideoRow } from "./database";

const encoder = new TextEncoder();

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64Url(data: Uint8Array): string {
  let binary = "";
  data.forEach((byte) => { binary += String.fromCharCode(byte); });
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function randomToken(bytes = 24): string {
  return base64Url(crypto.getRandomValues(new Uint8Array(bytes)));
}

export async function sha256(value: string): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

export async function passwordDigest(password: string, salt: string): Promise<string> {
  const material = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: encoder.encode(salt), iterations: 120_000 },
    material,
    256,
  );
  return bytesToHex(new Uint8Array(bits));
}

export async function requireUploadAuthorization(request: Request): Promise<Response | null> {
  const configured = platform().SOOM_UPLOAD_TOKEN;
  if (!configured) return Response.json({ error: "SOOM_UPLOAD_TOKEN is not configured" }, { status: 503 });
  const supplied = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!supplied || await sha256(supplied) !== await sha256(configured)) {
    return Response.json({ error: "Unauthorized" }, { status: 401 });
  }
  return null;
}

async function hmac(payload: string): Promise<string> {
  const secret = platform().SOOM_SHARE_SECRET ?? platform().SOOM_UPLOAD_TOKEN;
  if (!secret) throw new Error("SOOM_SHARE_SECRET is not configured");
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64Url(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(payload))));
}

export async function createAccessToken(slug: string, lifetimeSeconds = 86_400): Promise<string> {
  const payload = base64Url(encoder.encode(JSON.stringify({ slug, exp: Math.floor(Date.now() / 1000) + lifetimeSeconds })));
  return `${payload}.${await hmac(payload)}`;
}

export async function verifyAccessToken(token: string, slug: string): Promise<boolean> {
  const [payload, signature] = token.split(".");
  if (!payload || !signature || await hmac(payload) !== signature) return false;
  try {
    const normalized = payload.replaceAll("-", "+").replaceAll("_", "/");
    const decoded = JSON.parse(atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")));
    return decoded.slug === slug && Number(decoded.exp) > Math.floor(Date.now() / 1000);
  } catch {
    return false;
  }
}

function cookieValue(request: Request, name: string): string | null {
  const cookie = request.headers.get("cookie") ?? "";
  for (const item of cookie.split(";")) {
    const [key, ...value] = item.trim().split("=");
    if (key === name) return decodeURIComponent(value.join("="));
  }
  return null;
}

export async function authorizeShare(request: Request, video: VideoRow): Promise<"owner" | "viewer" | null> {
  if (video.expires_at && video.expires_at <= Date.now()) return null;
  const url = new URL(request.url);
  const ownerToken = url.searchParams.get("token") ?? request.headers.get("x-soom-owner-token");
  if (ownerToken && await sha256(ownerToken) === video.owner_token_hash) return "owner";
  if (video.privacy === "public") return "viewer";
  if (video.privacy === "password") {
    const access = cookieValue(request, `soom_${video.slug}`);
    if (access && await verifyAccessToken(access, video.slug)) return "viewer";
  }
  return null;
}

export async function viewerHash(request: Request): Promise<string> {
  const fingerprint = [
    request.headers.get("cf-connecting-ip") ?? "local",
    request.headers.get("user-agent") ?? "unknown",
  ].join("|");
  return sha256(fingerprint);
}
