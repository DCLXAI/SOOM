import { mkdir, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

type TranscriptWord = { word: string; start: number; end: number };
type ClaimedJob = {
  jobId: string;
  videoId: string;
  durationMs?: number | null;
  sourceURL: string;
  assetURL: string;
  transcript?: { words?: TranscriptWord[] } | null;
};

const origin = (process.env.SOOM_SHARE_ORIGIN ?? "http://localhost:3001").replace(/\/$/, "");
const token = process.env.SOOM_UPLOAD_TOKEN ?? "";
const workerId = process.env.SOOM_WORKER_ID ?? `transcoder-${crypto.randomUUID().slice(0, 8)}`;
const once = process.argv.includes("--once");

if (!token) throw new Error("SOOM_UPLOAD_TOKEN is required");

if (process.env.PORT) {
  Bun.serve({
    port: Number(process.env.PORT),
    fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === "/healthz" || path === "/") {
        return Response.json({ status: "ok", workerId, service: "soom-transcoder" });
      }
      return new Response("Not found", { status: 404 });
    },
  });
}

const headers = { authorization: `Bearer ${token}` };

async function api(path: string, init: RequestInit = {}): Promise<Response> {
  const response = await fetch(`${origin}${path}`, {
    ...init,
    headers: { ...headers, ...init.headers },
  });
  if (!response.ok && response.status !== 204) {
    throw new Error(`${init.method ?? "GET"} ${path}: ${response.status} ${await response.text()}`);
  }
  return response;
}

async function run(command: string[]) {
  const process = Bun.spawn(command, { stdout: "pipe", stderr: "pipe" });
  const [exitCode, stderr] = await Promise.all([process.exited, new Response(process.stderr).text()]);
  if (exitCode !== 0) throw new Error(`${command[0]} failed (${exitCode}): ${stderr.slice(-1_500)}`);
}

function timestamp(seconds: number): string {
  const millis = Math.max(0, Math.round(seconds * 1_000));
  const hours = Math.floor(millis / 3_600_000);
  const minutes = Math.floor((millis % 3_600_000) / 60_000);
  const secs = Math.floor((millis % 60_000) / 1_000);
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}.${String(millis % 1_000).padStart(3, "0")}`;
}

function makeVtt(words: TranscriptWord[]): string {
  const cues: string[] = ["WEBVTT", ""];
  for (let index = 0; index < words.length; index += 8) {
    const group = words.slice(index, index + 8);
    if (!group.length) continue;
    cues.push(`${timestamp(group[0].start)} --> ${timestamp(group.at(-1)?.end ?? group[0].end)}`);
    cues.push(group.map((item) => item.word.trim()).filter(Boolean).join(" "));
    cues.push("");
  }
  return cues.join("\n");
}

async function uploadAsset(job: ClaimedJob, file: string, name: string) {
  const response = await fetch(`${origin}${job.assetURL}?name=${encodeURIComponent(name)}`, {
    method: "PUT",
    headers,
    body: Bun.file(file),
  });
  if (!response.ok) throw new Error(`Asset ${name}: ${response.status} ${await response.text()}`);
}

async function transcode(job: ClaimedJob) {
  const directory = join(tmpdir(), `soom-${job.jobId}`);
  const hlsDirectory = join(directory, "hls");
  await mkdir(hlsDirectory, { recursive: true });
  const source = join(directory, "source.mp4");
  const playback = join(directory, "playback.mp4");
  const thumbnail = join(directory, "thumbnail.jpg");
  const waveform = join(directory, "waveform.png");
  const captions = join(directory, "captions.vtt");

  try {
    const sourceResponse = await api(job.sourceURL);
    await Bun.write(source, sourceResponse);
    await run([
      "ffmpeg", "-y", "-i", source,
      "-vf", "scale='min(1920,iw)':-2:flags=lanczos,fps=30",
      "-c:v", "libx264", "-preset", "fast", "-crf", "22", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", playback,
    ]);
    await run([
      "ffmpeg", "-y", "-i", playback, "-codec", "copy", "-start_number", "0",
      "-hls_time", "4", "-hls_playlist_type", "vod", "-hls_segment_filename", join(hlsDirectory, "segment-%04d.ts"),
      join(hlsDirectory, "index.m3u8"),
    ]);
    await run(["ffmpeg", "-y", "-ss", "1", "-i", playback, "-frames:v", "1", "-vf", "scale=1280:-2", thumbnail]);
    try {
      await run([
        "ffmpeg", "-y", "-i", playback, "-filter_complex",
        "aformat=channel_layouts=mono,showwavespic=s=1600x180:colors=#7656FF", "-frames:v", "1", waveform,
      ]);
    } catch {
      await run(["ffmpeg", "-y", "-f", "lavfi", "-i", "color=c=#EEEAFE:s=1600x180", "-frames:v", "1", waveform]);
    }
    const words = job.transcript?.words ?? [];
    if (words.length) await Bun.write(captions, makeVtt(words));

    await Promise.all([
      uploadAsset(job, playback, "playback.mp4"),
      uploadAsset(job, thumbnail, "thumbnail.jpg"),
      uploadAsset(job, waveform, "waveform.png"),
      ...(words.length ? [uploadAsset(job, captions, "captions.vtt")] : []),
    ]);
    for (const name of await readdir(hlsDirectory)) {
      await uploadAsset(job, join(hlsDirectory, name), `hls/${name}`);
    }
    await api(`/api/internal/jobs/${job.jobId}/complete`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        playback: "playback.mp4",
        hls: "hls/index.m3u8",
        thumbnail: "thumbnail.jpg",
        waveform: "waveform.png",
        captions: words.length ? "captions.vtt" : null,
        durationMs: job.durationMs,
      }),
    });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

async function claim(): Promise<ClaimedJob | null> {
  const response = await api("/api/internal/jobs/claim", { method: "POST", headers: { "x-soom-worker": workerId } });
  return response.status === 204 ? null : response.json() as Promise<ClaimedJob>;
}

async function cycle(): Promise<boolean> {
  const job = await claim();
  if (!job) return false;
  try {
    await transcode(job);
    console.log(JSON.stringify({ event: "job_completed", jobId: job.jobId, videoId: job.videoId }));
  } catch (error) {
    console.error(JSON.stringify({ event: "job_failed", jobId: job.jobId, message: error instanceof Error ? error.message : "Unknown transcode error" }));
    await api(`/api/internal/jobs/${job.jobId}/fail`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ error: error instanceof Error ? error.message : "Unknown transcode error" }),
    });
  }
  return true;
}

do {
  try {
    const worked = await cycle();
    if (once) break;
    if (!worked) await Bun.sleep(5_000);
  } catch (error) {
    console.error(JSON.stringify({ event: "poll_failed", message: error instanceof Error ? error.message : "Unknown poll error" }));
    if (once) throw error;
    await Bun.sleep(5_000);
  }
} while (true);
