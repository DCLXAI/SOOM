import { index, integer, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

export const videos = sqliteTable(
  "videos",
  {
    id: text("id").primaryKey(),
    slug: text("slug").notNull(),
    title: text("title").notNull(),
    status: text("status", { enum: ["uploading", "processing", "ready", "failed"] }).notNull(),
    privacy: text("privacy", { enum: ["private", "public", "password"] }).notNull(),
    passwordSalt: text("password_salt"),
    passwordHash: text("password_hash"),
    ownerTokenHash: text("owner_token_hash").notNull(),
    expiresAt: integer("expires_at"),
    allowDownload: integer("allow_download", { mode: "boolean" }).notNull().default(false),
    sourceKey: text("source_key").notNull(),
    playbackKey: text("playback_key"),
    hlsManifestKey: text("hls_manifest_key"),
    thumbnailKey: text("thumbnail_key"),
    waveformKey: text("waveform_key"),
    captionsKey: text("captions_key"),
    uploadId: text("upload_id").notNull(),
    totalBytes: integer("total_bytes").notNull(),
    receivedBytes: integer("received_bytes").notNull().default(0),
    mimeType: text("mime_type").notNull().default("video/mp4"),
    durationMs: integer("duration_ms"),
    transcriptJson: text("transcript_json"),
    taskSpecJson: text("taskspec_json"),
    createdAt: integer("created_at").notNull(),
    updatedAt: integer("updated_at").notNull(),
  },
  (table) => [
    uniqueIndex("idx_videos_slug").on(table.slug),
    index("idx_videos_status_created").on(table.status, table.createdAt),
  ],
);

export const uploadParts = sqliteTable(
  "upload_parts",
  {
    videoId: text("video_id").notNull(),
    partNumber: integer("part_number").notNull(),
    etag: text("etag").notNull(),
    sizeBytes: integer("size_bytes").notNull(),
    createdAt: integer("created_at").notNull(),
  },
  (table) => [uniqueIndex("idx_upload_parts_video_part").on(table.videoId, table.partNumber)],
);

export const processingJobs = sqliteTable(
  "processing_jobs",
  {
    id: text("id").primaryKey(),
    videoId: text("video_id").notNull(),
    status: text("status", { enum: ["pending", "processing", "completed", "failed"] }).notNull(),
    attempts: integer("attempts").notNull().default(0),
    leaseUntil: integer("lease_until"),
    workerId: text("worker_id"),
    error: text("error"),
    createdAt: integer("created_at").notNull(),
    updatedAt: integer("updated_at").notNull(),
  },
  (table) => [index("idx_processing_jobs_status_created").on(table.status, table.createdAt)],
);

export const comments = sqliteTable(
  "comments",
  {
    id: text("id").primaryKey(),
    videoId: text("video_id").notNull(),
    displayName: text("display_name").notNull(),
    body: text("body").notNull(),
    tMs: integer("t_ms").notNull(),
    createdAt: integer("created_at").notNull(),
  },
  (table) => [index("idx_comments_video_created").on(table.videoId, table.createdAt)],
);

export const reactions = sqliteTable(
  "reactions",
  {
    id: text("id").primaryKey(),
    videoId: text("video_id").notNull(),
    emoji: text("emoji").notNull(),
    tMs: integer("t_ms").notNull(),
    viewerHash: text("viewer_hash").notNull(),
    createdAt: integer("created_at").notNull(),
  },
  (table) => [
    index("idx_reactions_video_time").on(table.videoId, table.tMs),
    uniqueIndex("idx_reactions_viewer_emoji_time").on(table.videoId, table.viewerHash, table.emoji, table.tMs),
  ],
);

export const viewEvents = sqliteTable(
  "view_events",
  {
    id: text("id").primaryKey(),
    videoId: text("video_id").notNull(),
    viewerHash: text("viewer_hash").notNull(),
    event: text("event").notNull(),
    tMs: integer("t_ms").notNull().default(0),
    watchedMs: integer("watched_ms").notNull().default(0),
    referrerHost: text("referrer_host"),
    createdAt: integer("created_at").notNull(),
  },
  (table) => [index("idx_view_events_video_created").on(table.videoId, table.createdAt)],
);
