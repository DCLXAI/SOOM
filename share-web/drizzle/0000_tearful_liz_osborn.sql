CREATE TABLE `comments` (
	`id` text PRIMARY KEY NOT NULL,
	`video_id` text NOT NULL,
	`display_name` text NOT NULL,
	`body` text NOT NULL,
	`t_ms` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `idx_comments_video_created` ON `comments` (`video_id`,`created_at`);--> statement-breakpoint
CREATE TABLE `processing_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`video_id` text NOT NULL,
	`status` text NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`lease_until` integer,
	`worker_id` text,
	`error` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `idx_processing_jobs_status_created` ON `processing_jobs` (`status`,`created_at`);--> statement-breakpoint
CREATE TABLE `reactions` (
	`id` text PRIMARY KEY NOT NULL,
	`video_id` text NOT NULL,
	`emoji` text NOT NULL,
	`t_ms` integer NOT NULL,
	`viewer_hash` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `idx_reactions_video_time` ON `reactions` (`video_id`,`t_ms`);--> statement-breakpoint
CREATE UNIQUE INDEX `idx_reactions_viewer_emoji_time` ON `reactions` (`video_id`,`viewer_hash`,`emoji`,`t_ms`);--> statement-breakpoint
CREATE TABLE `upload_parts` (
	`video_id` text NOT NULL,
	`part_number` integer NOT NULL,
	`etag` text NOT NULL,
	`size_bytes` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `idx_upload_parts_video_part` ON `upload_parts` (`video_id`,`part_number`);--> statement-breakpoint
CREATE TABLE `videos` (
	`id` text PRIMARY KEY NOT NULL,
	`slug` text NOT NULL,
	`title` text NOT NULL,
	`status` text NOT NULL,
	`privacy` text NOT NULL,
	`password_salt` text,
	`password_hash` text,
	`owner_token_hash` text NOT NULL,
	`expires_at` integer,
	`allow_download` integer DEFAULT false NOT NULL,
	`source_key` text NOT NULL,
	`playback_key` text,
	`hls_manifest_key` text,
	`thumbnail_key` text,
	`waveform_key` text,
	`captions_key` text,
	`upload_id` text NOT NULL,
	`total_bytes` integer NOT NULL,
	`received_bytes` integer DEFAULT 0 NOT NULL,
	`mime_type` text DEFAULT 'video/mp4' NOT NULL,
	`duration_ms` integer,
	`transcript_json` text,
	`taskspec_json` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `idx_videos_slug` ON `videos` (`slug`);--> statement-breakpoint
CREATE INDEX `idx_videos_status_created` ON `videos` (`status`,`created_at`);--> statement-breakpoint
CREATE TABLE `view_events` (
	`id` text PRIMARY KEY NOT NULL,
	`video_id` text NOT NULL,
	`viewer_hash` text NOT NULL,
	`event` text NOT NULL,
	`t_ms` integer DEFAULT 0 NOT NULL,
	`watched_ms` integer DEFAULT 0 NOT NULL,
	`referrer_host` text,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `idx_view_events_video_created` ON `view_events` (`video_id`,`created_at`);