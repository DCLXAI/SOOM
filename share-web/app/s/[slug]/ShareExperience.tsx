"use client";

import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";

type TranscriptWord = { word: string; start: number; end: number };
type Evidence = { tMs: number; quote?: string; frame?: string };
type Task = { id?: string; title: string; change: { instruction: string }; confidence: number; evidence: Evidence[] };
type Comment = { id: string; displayName: string; body: string; tMs: number; createdAt: number };
type Reaction = { emoji: string; tMs: number; count: number };
type ShareTab = "tasks" | "transcript" | "comments" | "analytics";
type ShareData = {
  slug: string;
  title: string;
  status: string;
  privacy: "private" | "public" | "password";
  expiresAt: number | null;
  isOwner: boolean;
  allowDownload: boolean;
  durationMs: number | null;
  createdAt: number;
  playbackURL: string;
  captionsURL: string | null;
  thumbnailURL: string | null;
  waveformURL: string | null;
  downloadURL: string | null;
  transcript: { text: string; words: TranscriptWord[] };
  taskSpec: { goal: string; summary: string; tasks: Task[]; unresolvedQuestions?: string[] } | null;
  comments: Comment[];
  reactions: Reaction[];
};

const demoData: ShareData = {
  slug: "demo",
  title: "랜딩 페이지 hero와 모바일 카드 수정",
  status: "ready",
  privacy: "private",
  expiresAt: Date.UTC(2026, 7, 20, 12, 30),
  isOwner: true,
  allowDownload: false,
  durationMs: 58_000,
  createdAt: Date.UTC(2026, 7, 13, 12, 30),
  playbackURL: "",
  captionsURL: null,
  thumbnailURL: null,
  waveformURL: null,
  downloadURL: null,
  transcript: {
    text: "여기 hero가 너무 커요. 높이를 30퍼센트 줄이고 CTA를 오른쪽으로 옮겨주세요. 모바일에서는 이 카드를 한 열로 보여주세요.",
    words: [
      { word: "여기", start: 3.1, end: 3.4 }, { word: "hero가", start: 3.4, end: 3.9 },
      { word: "너무", start: 3.9, end: 4.2 }, { word: "커요.", start: 4.2, end: 4.7 },
      { word: "높이를", start: 5.1, end: 5.6 }, { word: "30퍼센트", start: 5.6, end: 6.2 },
      { word: "줄이고", start: 6.2, end: 6.8 }, { word: "CTA를", start: 12.1, end: 12.6 },
      { word: "오른쪽으로", start: 12.6, end: 13.3 }, { word: "옮겨주세요.", start: 13.3, end: 14.1 },
      { word: "모바일에서는", start: 22.1, end: 22.8 }, { word: "이", start: 22.8, end: 23.0 },
      { word: "카드를", start: 23.0, end: 23.4 }, { word: "한", start: 23.4, end: 23.6 },
      { word: "열로", start: 23.6, end: 24.0 }, { word: "보여주세요.", start: 24.0, end: 24.8 },
    ],
  },
  taskSpec: {
    goal: "랜딩 페이지의 시각적 밀도와 모바일 반응형 개선",
    summary: "hero 높이, CTA 정렬, 모바일 카드 레이아웃을 세 가지 검증 가능한 작업으로 정리했습니다.",
    tasks: [
      { title: "Hero 높이 축소", change: { instruction: "Hero section의 현재 높이를 약 30% 줄입니다." }, confidence: .94, evidence: [{ tMs: 3_500, quote: "hero가 너무 커요" }] },
      { title: "CTA 오른쪽 정렬", change: { instruction: "Primary CTA를 hero 우측 정렬 영역으로 이동합니다." }, confidence: .89, evidence: [{ tMs: 12_600, quote: "CTA를 오른쪽으로" }] },
      { title: "모바일 카드 1열", change: { instruction: "모바일 breakpoint에서 카드 grid를 단일 열로 전환합니다." }, confidence: .97, evidence: [{ tMs: 22_800, quote: "카드를 한 열로" }] },
    ],
  },
  comments: [
    { id: "demo-1", displayName: "민지", body: "이 방향 좋아요. 모바일 간격만 디자인 토큰에 맞춰 주세요.", tMs: 23_000, createdAt: Date.UTC(2026, 7, 13, 12, 40) },
  ],
  reactions: [{ emoji: "👍", tMs: 13_000, count: 2 }, { emoji: "🎉", tMs: 24_000, count: 1 }],
};

function time(ms: number) {
  const seconds = Math.max(0, Math.floor(ms / 1_000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

async function responseJSON<T>(response: Response): Promise<T> {
  return response.json() as Promise<T>;
}

export function ShareExperience({ slug, demo = false }: { slug: string; demo?: boolean }) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const watchedRef = useRef(0);
  const [data, setData] = useState<ShareData | null>(demo ? demoData : null);
  const [loading, setLoading] = useState(!demo);
  const [locked, setLocked] = useState(false);
  const [requiresPassword, setRequiresPassword] = useState(false);
  const [password, setPassword] = useState("");
  const [passwordError, setPasswordError] = useState("");
  const [query, setQuery] = useState("");
  const [tab, setTab] = useState<ShareTab>("tasks");
  const [speed, setSpeed] = useState(1);
  const [comment, setComment] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [copied, setCopied] = useState(false);
  const [notice, setNotice] = useState("");
  const [analytics, setAnalytics] = useState<Record<string, unknown> | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const [settingsPrivacy, setSettingsPrivacy] = useState<ShareData["privacy"]>("private");
  const [settingsPassword, setSettingsPassword] = useState("");
  const [settingsExpiration, setSettingsExpiration] = useState(7);
  const [settingsDownload, setSettingsDownload] = useState(false);

  const suffix = typeof window === "undefined" ? "" : window.location.search;
  const load = useCallback(async () => {
    if (demo) return;
    setLoading(true);
    const response = await fetch(`/api/shares/${slug}${window.location.search}`, { credentials: "include" });
    const body = await responseJSON<ShareData & { error?: string; requiresPassword?: boolean }>(response);
    if (response.status === 401) {
      setLocked(true);
      setRequiresPassword(Boolean(body.requiresPassword));
      setLoading(false);
      return;
    }
    if (!response.ok) {
      setNotice(body.error ?? "공유 영상을 불러오지 못했습니다.");
      setLoading(false);
      return;
    }
    setData(body);
    setLocked(false);
    setLoading(false);
  }, [demo, slug]);

  useEffect(() => {
    let active = true;
    void Promise.resolve().then(() => {
      if (active) void load();
    });
    return () => { active = false; };
  }, [load]);
  useEffect(() => {
    if (!data || demo) return;
    void fetch(`/api/shares/${slug}/views${suffix}`, {
      method: "POST", credentials: "include", headers: { "content-type": "application/json" },
      body: JSON.stringify({ event: "open", referrer: document.referrer }),
    });
  }, [data, demo, slug, suffix]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    video.playbackRate = speed;
  }, [speed, data]);

  useEffect(() => {
    if (!data?.isOwner || tab !== "analytics" || demo) return;
    fetch(`/api/shares/${slug}/analytics${suffix}`, { credentials: "include" })
      .then((response) => responseJSON<Record<string, unknown>>(response)).then(setAnalytics).catch(() => setAnalytics(null));
  }, [data?.isOwner, tab, demo, slug, suffix]);

  const seek = (milliseconds: number) => {
    if (videoRef.current) {
      videoRef.current.currentTime = milliseconds / 1_000;
      void videoRef.current.play();
    }
  };

  const transcriptGroups = useMemo(() => {
    const words = data?.transcript.words ?? [];
    const groups: { text: string; start: number }[] = [];
    for (let index = 0; index < words.length; index += 10) {
      const group = words.slice(index, index + 10);
      const text = group.map((word) => word.word).join(" ");
      if (!query || text.toLocaleLowerCase().includes(query.toLocaleLowerCase())) groups.push({ text, start: group[0]?.start ?? 0 });
    }
    return groups;
  }, [data, query]);

  async function unlock(event: FormEvent) {
    event.preventDefault();
    setPasswordError("");
    const response = await fetch(`/api/shares/${slug}/unlock`, {
      method: "POST", credentials: "include", headers: { "content-type": "application/json" }, body: JSON.stringify({ password }),
    });
    if (!response.ok) {
      const body = await responseJSON<{ error?: string }>(response);
      setPasswordError(body.error ?? "비밀번호를 확인해 주세요.");
      return;
    }
    await load();
  }

  async function copyLink(atCurrentTime = false) {
    const url = new URL(window.location.href);
    if (atCurrentTime && videoRef.current) url.searchParams.set("t", String(Math.floor(videoRef.current.currentTime)));
    await navigator.clipboard.writeText(url.toString());
    setCopied(true);
    setTimeout(() => setCopied(false), 1_600);
  }

  async function addComment(event: FormEvent) {
    event.preventDefault();
    if (!data || !comment.trim()) return;
    if (demo) {
      setData({ ...data, comments: [...data.comments, { id: crypto.randomUUID(), displayName: displayName || "나", body: comment, tMs: Math.round((videoRef.current?.currentTime ?? 0) * 1_000), createdAt: Date.now() }] });
      setComment("");
      return;
    }
    const response = await fetch(`/api/shares/${slug}/comments${suffix}`, {
      method: "POST", credentials: "include", headers: { "content-type": "application/json" },
      body: JSON.stringify({ displayName, body: comment, tMs: Math.round((videoRef.current?.currentTime ?? 0) * 1_000) }),
    });
    if (response.ok) {
      const created = await responseJSON<Comment>(response);
      setData({ ...data, comments: [...data.comments, created] });
      setComment("");
    }
  }

  async function react(emoji: string) {
    if (!data) return;
    const tMs = Math.round((videoRef.current?.currentTime ?? 0) * 1_000);
    if (!demo) await fetch(`/api/shares/${slug}/reactions${suffix}`, {
      method: "POST", credentials: "include", headers: { "content-type": "application/json" }, body: JSON.stringify({ emoji, tMs }),
    });
    setNotice(`${time(tMs)}에 ${emoji} 반응을 남겼습니다.`);
    setTimeout(() => setNotice(""), 1_800);
  }

  async function saveSettings(event: FormEvent) {
    event.preventDefault();
    if (!data) return;
    if (settingsPrivacy === "password" && settingsPassword.length < 4) {
      setNotice("비밀번호는 4자 이상이어야 합니다.");
      return;
    }
    const expiresAt = settingsExpiration > 0 ? new Date(Date.now() + settingsExpiration * 86_400_000).toISOString() : null;
    if (!demo) {
      const response = await fetch(`/api/shares/${slug}/settings${suffix}`, {
        method: "PATCH", credentials: "include", headers: { "content-type": "application/json" },
        body: JSON.stringify({ privacy: settingsPrivacy, password: settingsPrivacy === "password" ? settingsPassword : undefined, expiresAt, allowDownload: settingsDownload }),
      });
      if (!response.ok) {
        const body = await responseJSON<{ error?: string }>(response);
        setNotice(body.error ?? "공유 설정을 저장하지 못했습니다.");
        return;
      }
    }
    setData({ ...data, privacy: settingsPrivacy, expiresAt: expiresAt ? Date.parse(expiresAt) : null, allowDownload: settingsDownload });
    setShowSettings(false);
    setNotice("공유 설정을 저장했습니다.");
    setTimeout(() => setNotice(""), 1_800);
  }

  function openSettings() {
    if (!data) return;
    setSettingsPrivacy(data.privacy);
    setSettingsDownload(data.allowDownload);
    setSettingsExpiration(data.expiresAt ? Math.max(1, Math.round((data.expiresAt - Date.now()) / 86_400_000)) : 0);
    setShowSettings(true);
  }

  function report(event: string) {
    if (demo) return;
    const video = videoRef.current;
    void fetch(`/api/shares/${slug}/views${suffix}`, {
      method: "POST", credentials: "include", headers: { "content-type": "application/json" },
      body: JSON.stringify({ event, tMs: Math.round((video?.currentTime ?? 0) * 1_000), watchedMs: watchedRef.current }),
    });
  }

  if (loading) return <main className="center-state"><div className="brand-mark" /><p>안전하게 녹화를 불러오는 중…</p></main>;
  if (locked) return (
    <main className="center-state">
      <Link className="brand" href="/"><span className="brand-mark" /><strong>SOOM</strong></Link>
      <section className="lock-card">
        <span className="lock-icon">🔒</span><h1>비공개 녹화입니다</h1>
        <p>{requiresPassword ? "공유받은 비밀번호를 입력해 주세요." : "소유자가 전달한 비공개 링크로만 볼 수 있습니다."}</p>
        {requiresPassword && <form onSubmit={unlock}><input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="비밀번호" aria-label="공유 비밀번호" /><button>녹화 열기</button></form>}
        {passwordError && <p className="error-text">{passwordError}</p>}
      </section>
    </main>
  );
  if (!data) return <main className="center-state"><h1>녹화를 찾을 수 없습니다</h1><p>{notice}</p></main>;

  return (
    <main className="share-shell">
      <header className="topbar">
        <Link className="brand" href="/"><span className="brand-mark" /><strong>SOOM</strong></Link>
        <div className="top-actions">
          <span className="privacy-pill">{data.privacy === "public" ? "공개" : data.privacy === "password" ? "암호 보호" : "비공개"}</span>
          {data.isOwner && <button className="ghost-button" onClick={openSettings}>공유 설정</button>}
          <button className="ghost-button" onClick={() => copyLink(true)}>↗ 현재 시점</button>
          <button className="primary-button" onClick={() => copyLink(false)}>{copied ? "복사됨" : "공유 링크 복사"}</button>
        </div>
      </header>

      <div className="content-grid">
        <section className="main-column">
          <div className="title-row">
            <div><p className="eyebrow">SOOM RECORDING</p><h1>{data.title}</h1><p className="meta">{new Date(data.createdAt).toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })} · {time(data.durationMs ?? 0)}</p></div>
            {data.status !== "ready" && <span className="processing-pill">파생 영상 처리 중</span>}
          </div>

          <div className="player-card">
            {data.playbackURL ? (
              <video
                ref={videoRef} controls playsInline preload="metadata" poster={data.thumbnailURL ?? undefined}
                onLoadedMetadata={(event) => { const t = Number(new URLSearchParams(window.location.search).get("t")); if (t > 0) event.currentTarget.currentTime = t; }}
                onPlay={() => report("play")}
                onTimeUpdate={(event) => { watchedRef.current = Math.max(watchedRef.current, Math.round(event.currentTarget.currentTime * 1_000)); }}
                onEnded={() => report("complete")}
              >
                <source src={data.playbackURL} type="video/mp4" />
                <track default={Boolean(data.captionsURL)} kind="captions" srcLang="ko" label="한국어" src={data.captionsURL ?? "data:text/vtt,WEBVTT%0A%0A"} />
              </video>
            ) : (
              <div className="demo-stage"><div className="demo-window"><span /><span /><span /><div className="demo-hero"><b>Build what users mean.</b><i /><i /></div><div className="demo-cards"><i /><i /><i /></div></div><div className="face-bubble">SOOM</div><div className="cursor-dot" /></div>
            )}
            <div className="player-toolbar">
              <label>속도 <select value={speed} onChange={(event) => setSpeed(Number(event.target.value))}>{[.5, .75, 1, 1.25, 1.5, 2].map((value) => <option key={value} value={value}>{value}×</option>)}</select></label>
              <div className="reaction-bar">{["👍", "❤️", "🎉", "😂", "👀"].map((emoji) => <button key={emoji} onClick={() => react(emoji)} aria-label={`${emoji} 반응`}>{emoji}</button>)}</div>
              <button onClick={async () => { const video = videoRef.current as (HTMLVideoElement & { requestPictureInPicture?: () => Promise<PictureInPictureWindow> }) | null; if (video?.requestPictureInPicture) await video.requestPictureInPicture(); }}>PIP</button>
              {data.downloadURL && <a href={data.downloadURL}>다운로드</a>}
            </div>
            {/* The generated waveform has an intrinsic timeline-dependent width, so image optimization would distort seeking alignment. */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            {data.waveformURL && <img className="waveform" src={data.waveformURL} alt="오디오 파형" />}
          </div>

          <nav className="tabs" aria-label="녹화 정보">
            {(["tasks", "transcript", "comments", ...(data.isOwner ? ["analytics"] : [])] as ShareTab[]).map((item) => (
              <button key={item} className={tab === item ? "active" : ""} onClick={() => setTab(item)}>
                {item === "tasks" ? `AI 작업 ${data.taskSpec?.tasks.length ?? 0}` : item === "transcript" ? "Transcript" : item === "comments" ? `댓글 ${data.comments.length}` : "시청 분석"}
              </button>
            ))}
          </nav>

          <section className="tab-panel">
            {tab === "tasks" && <TasksPanel data={data} seek={seek} />}
            {tab === "transcript" && <div><div className="search-box">⌕<input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="자막에서 단어 검색" /></div><div className="transcript-list">{transcriptGroups.map((group) => <button key={`${group.start}-${group.text}`} onClick={() => seek(group.start * 1_000)}><time>{time(group.start * 1_000)}</time><span>{group.text}</span></button>)}</div></div>}
            {tab === "comments" && <CommentsPanel comments={data.comments} seek={seek} comment={comment} setComment={setComment} displayName={displayName} setDisplayName={setDisplayName} submit={addComment} />}
            {tab === "analytics" && <AnalyticsPanel analytics={analytics} />}
          </section>
        </section>

        <aside className="side-column">
          <div className="agent-card"><span className="sparkle">✦</span><p className="eyebrow">AI INTENT COMPILER</p><h2>{data.taskSpec?.goal ?? "TaskSpec 처리 중"}</h2><p>{data.taskSpec?.summary ?? "영상은 이미 볼 수 있습니다. 구조화된 작업은 곧 표시됩니다."}</p><div className="agent-destination"><span>⌘</span><div><b>Codex / Claude Code</b><small>실행 가능한 작업 지시</small></div><strong>준비</strong></div></div>
          <div className="timeline-card"><h3>타임라인 활동</h3>{data.comments.slice(0, 3).map((item) => <button key={item.id} onClick={() => seek(item.tMs)}><span className="avatar">{item.displayName.slice(0, 1)}</span><span><b>{item.displayName}</b><small>{item.body}</small></span><time>{time(item.tMs)}</time></button>)}{data.reactions.map((item) => <button key={`${item.emoji}-${item.tMs}`} onClick={() => seek(item.tMs)}><span className="emoji">{item.emoji}</span><span><b>{item.count}명이 반응</b><small>이 순간 다시 보기</small></span><time>{time(item.tMs)}</time></button>)}</div>
        </aside>
      </div>
      {showSettings && (
        <dialog
          open
          className="modal-backdrop"
          aria-modal="true"
          aria-labelledby="share-settings-title"
        >
          <button type="button" className="modal-dismiss" onClick={() => setShowSettings(false)} aria-label="공유 설정 닫기" />
          <form className="settings-modal" onSubmit={saveSettings}>
            <div className="modal-heading">
              <div><p className="eyebrow">OWNER CONTROLS</p><h2 id="share-settings-title">공유 설정</h2></div>
              <button type="button" onClick={() => setShowSettings(false)} aria-label="공유 설정 닫기">×</button>
            </div>
            <label>공개 범위<select value={settingsPrivacy} onChange={(event) => setSettingsPrivacy(event.target.value as ShareData["privacy"])}><option value="private">비공개 링크</option><option value="password">비밀번호 보호</option><option value="public">공개</option></select></label>
            {settingsPrivacy === "password" && <label>공유 비밀번호<input type="password" minLength={4} value={settingsPassword} onChange={(event) => setSettingsPassword(event.target.value)} placeholder="4자 이상" /></label>}
            <label>링크 만료<select value={settingsExpiration} onChange={(event) => setSettingsExpiration(Number(event.target.value))}><option value={0}>만료 없음</option><option value={1}>1일</option><option value={7}>7일</option><option value={30}>30일</option></select></label>
            <label className="check-row" aria-label="원본 다운로드 허용"><input type="checkbox" checked={settingsDownload} onChange={(event) => setSettingsDownload(event.target.checked)} /><span><b>원본 다운로드 허용</b><small>시청자가 MP4를 내려받을 수 있습니다.</small></span></label>
            <button className="primary-button">설정 저장</button>
          </form>
        </dialog>
      )}
      {notice && <div className="toast">{notice}</div>}
    </main>
  );
}

function TasksPanel({ data, seek }: { data: ShareData; seek: (milliseconds: number) => void }) {
  if (!data.taskSpec) return <div className="empty-panel"><span>✦</span><h3>AI가 TaskSpec을 정리하고 있습니다</h3><p>영상은 먼저 공유됐고 작업 목록은 자동으로 갱신됩니다.</p></div>;
  return <div className="tasks-list">{data.taskSpec.tasks.map((task, index) => { const evidence = task.evidence[0]; return <article key={task.id ?? `${index}-${task.title}`}><span className="task-number">{String(index + 1).padStart(2, "0")}</span><div><h3>{task.title}</h3><p>{task.change.instruction}</p>{evidence && <button onClick={() => seek(evidence.tMs)}>▶ {time(evidence.tMs)} · “{evidence.quote ?? "화면 근거"}”</button>}</div><span className="confidence">{Math.round(task.confidence * 100)}%</span></article>; })}</div>;
}

function CommentsPanel(props: { comments: Comment[]; seek: (ms: number) => void; comment: string; setComment: (value: string) => void; displayName: string; setDisplayName: (value: string) => void; submit: (event: FormEvent) => void }) {
  return <div className="comments-panel"><form onSubmit={props.submit}><input className="name-input" value={props.displayName} onChange={(event) => props.setDisplayName(event.target.value)} placeholder="이름" /><textarea value={props.comment} onChange={(event) => props.setComment(event.target.value)} placeholder="현재 재생 시점에 댓글 남기기" /><button>댓글 남기기</button></form>{props.comments.map((item) => <article key={item.id}><span className="avatar">{item.displayName.slice(0, 1)}</span><div><b>{item.displayName}</b><button onClick={() => props.seek(item.tMs)}>{time(item.tMs)}</button><p>{item.body}</p></div></article>)}</div>;
}

function AnalyticsPanel({ analytics }: { analytics: Record<string, unknown> | null }) {
  const summary = (analytics?.summary ?? {}) as Record<string, number>;
  const cards = [["고유 시청자", summary.uniqueViewers ?? 0], ["재생 완료", summary.completions ?? 0], ["평균 시청", time(summary.averageWatchMs ?? 0)], ["최장 시청", time(summary.longestWatchMs ?? 0)]];
  return <div className="analytics-grid">{cards.map(([label, value]) => <div key={String(label)}><small>{label}</small><strong>{value}</strong></div>)}</div>;
}
