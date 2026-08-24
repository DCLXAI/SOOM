import { platform } from "./platform";

const statements = [
  `CREATE TABLE IF NOT EXISTS videos (
    id TEXT PRIMARY KEY, slug TEXT NOT NULL UNIQUE, title TEXT NOT NULL, status TEXT NOT NULL,
    privacy TEXT NOT NULL, password_salt TEXT, password_hash TEXT, owner_token_hash TEXT NOT NULL,
    expires_at INTEGER, allow_download INTEGER NOT NULL DEFAULT 0, source_key TEXT NOT NULL,
    playback_key TEXT, hls_manifest_key TEXT, thumbnail_key TEXT, waveform_key TEXT, captions_key TEXT,
    upload_id TEXT NOT NULL, total_bytes INTEGER NOT NULL, received_bytes INTEGER NOT NULL DEFAULT 0,
    mime_type TEXT NOT NULL DEFAULT 'video/mp4', duration_ms INTEGER, transcript_json TEXT,
    taskspec_json TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
  )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_videos_slug ON videos(slug)`,
  `CREATE INDEX IF NOT EXISTS idx_videos_status_created ON videos(status, created_at)`,
  `CREATE TABLE IF NOT EXISTS upload_parts (
    video_id TEXT NOT NULL, part_number INTEGER NOT NULL, etag TEXT NOT NULL,
    size_bytes INTEGER NOT NULL, created_at INTEGER NOT NULL,
    UNIQUE(video_id, part_number)
  )`,
  `CREATE TABLE IF NOT EXISTS processing_jobs (
    id TEXT PRIMARY KEY, video_id TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
    lease_until INTEGER, worker_id TEXT, error TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_processing_jobs_status_created ON processing_jobs(status, created_at)`,
  `CREATE TABLE IF NOT EXISTS comments (
    id TEXT PRIMARY KEY, video_id TEXT NOT NULL, display_name TEXT NOT NULL, body TEXT NOT NULL,
    t_ms INTEGER NOT NULL, created_at INTEGER NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_comments_video_created ON comments(video_id, created_at)`,
  `CREATE TABLE IF NOT EXISTS reactions (
    id TEXT PRIMARY KEY, video_id TEXT NOT NULL, emoji TEXT NOT NULL, t_ms INTEGER NOT NULL,
    viewer_hash TEXT NOT NULL, created_at INTEGER NOT NULL,
    UNIQUE(video_id, viewer_hash, emoji, t_ms)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_reactions_video_time ON reactions(video_id, t_ms)`,
  `CREATE TABLE IF NOT EXISTS view_events (
    id TEXT PRIMARY KEY, video_id TEXT NOT NULL, viewer_hash TEXT NOT NULL, event TEXT NOT NULL,
    t_ms INTEGER NOT NULL DEFAULT 0, watched_ms INTEGER NOT NULL DEFAULT 0,
    referrer_host TEXT, created_at INTEGER NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS idx_view_events_video_created ON view_events(video_id, created_at)`,
];

let initialized: Promise<void> | undefined;

export function ensureDatabase(): Promise<void> {
  if (initialized) return initialized;
  const db = platform().DB;
  const initialization = db.batch(statements.map((sql) => db.prepare(sql))).then(async () => {
    await db.prepare("PRAGMA optimize").run();
  });
  initialized = initialization;
  return initialization;
}

export type VideoRow = {
  id: string;
  slug: string;
  title: string;
  status: "uploading" | "processing" | "ready" | "failed";
  privacy: "private" | "public" | "password";
  password_salt: string | null;
  password_hash: string | null;
  owner_token_hash: string;
  expires_at: number | null;
  allow_download: number;
  source_key: string;
  playback_key: string | null;
  hls_manifest_key: string | null;
  thumbnail_key: string | null;
  waveform_key: string | null;
  captions_key: string | null;
  upload_id: string;
  total_bytes: number;
  received_bytes: number;
  mime_type: string;
  duration_ms: number | null;
  transcript_json: string | null;
  taskspec_json: string | null;
  created_at: number;
  updated_at: number;
};

export async function videoBySlug(slug: string): Promise<VideoRow | null> {
  await ensureDatabase();
  return (await platform().DB.prepare("SELECT * FROM videos WHERE slug = ? LIMIT 1").bind(slug).first<VideoRow>()) ?? null;
}

export async function videoById(id: string): Promise<VideoRow | null> {
  await ensureDatabase();
  return (await platform().DB.prepare("SELECT * FROM videos WHERE id = ? LIMIT 1").bind(id).first<VideoRow>()) ?? null;
}
