import { env } from "cloudflare:workers";

export interface PlatformEnv {
  DB: D1Database;
  MEDIA: R2Bucket;
  SOOM_UPLOAD_TOKEN?: string;
  SOOM_SHARE_SECRET?: string;
}

export function platform(): PlatformEnv {
  return env as unknown as PlatformEnv;
}
