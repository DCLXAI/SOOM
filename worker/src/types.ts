export type Nullable<T> = T | null;

export interface PointValue {
  x: number;
  y: number;
}

export interface ProjectContext {
  name: Nullable<string>;
  rootPath: Nullable<string>;
  gitBranch: Nullable<string>;
  headCommit: Nullable<string>;
}

export interface CaptureArtifact {
  path: string;
  startOffsetMs: number;
}

export interface SessionManifest {
  schemaVersion: string;
  sessionId: string;
  state: string;
  durationMs?: number;
  // Swift Codable omits nil optional properties from session.json. The worker
  // canonicalizes these back to explicit nulls before model input and output.
  project: Partial<ProjectContext>;
  artifacts: {
    recording?: CaptureArtifact;
    microphone?: CaptureArtifact;
    eventLog: CaptureArtifact;
    frameIndex: CaptureArtifact;
    transcript?: CaptureArtifact;
    taskSpec?: CaptureArtifact;
  };
  privacy: {
    recordsRawKeystrokesLocally: boolean;
    recordsTypingActivityLocally?: boolean;
    recordsSafeShortcutsLocally?: boolean;
    evidenceFramesIncludeCamera?: boolean;
    uploadsRawKeystrokes: boolean;
    uploadsRecordingFile: boolean;
    safetyIdentifier: string;
  };
}

export interface InputEvent {
  sequence: number;
  tMs: number;
  kind:
    | "mouseDown"
    | "mouseUp"
    | "mouseDragged"
    | "scroll"
    | "keyDown"
    | "keyUp"
    | "modifiersChanged"
    | "captureGap";
  position?: {
    displayNormalizedTopLeft: PointValue;
  };
  mouseButton?: string;
  scrollDeltaX?: number;
  scrollDeltaY?: number;
  keyCode?: number;
  characters?: string;
  shortcut?: string;
  modifiers?: string[];
  context?: {
    appName?: string;
    bundleIdentifier?: string;
    windowTitle?: string;
  };
  reason?: string;
}

export interface SanitizedContext {
  appName?: string;
  bundleIdentifier?: string;
}

export interface SanitizedEvent {
  kind: "pointer" | "scroll" | "shortcut" | "typingActivity" | "captureGap";
  startMs: number;
  endMs: number;
  keyCount?: number;
  shortcut?: string;
  pointerKind?: string;
  position?: PointValue;
  scrollDeltaX?: number;
  scrollDeltaY?: number;
  context: SanitizedContext | undefined;
  reason?: string;
}

export interface FrameCandidate {
  file: string;
  tMs: number;
  kind: "first" | "last" | "click" | "afterClick" | "scrollSettled" | "typingSettled" | "periodic";
  clickPosition?: PointValue;
}

export interface TranscriptWord {
  word: string;
  startMs: number;
  endMs: number;
}

export interface RawTranscriptWord {
  word: string;
  start: number;
  end: number;
}

export interface TranscriptDocument {
  text: string;
  language: Nullable<string>;
  timeUnit: "ms";
  words: TranscriptWord[];
}

export interface RawTranscriptDocument {
  text: string;
  language: Nullable<string>;
  words: RawTranscriptWord[];
}

export interface Evidence {
  kind: "speech" | "click" | "frame";
  tMs: number;
  frame: Nullable<string>;
  quote: Nullable<string>;
  position: Nullable<PointValue & { coordinateSpace: "displayNormalizedTopLeft" }>;
}

export interface TaskSpec {
  schemaVersion: "1.0";
  sessionId: string;
  project: ProjectContext;
  goal: string;
  summary: string;
  tasks: Array<{
    id: string;
    title: string;
    target: {
      description: string;
      app: Nullable<string>;
      windowTitle: Nullable<string>;
      region: Nullable<{
        x: number;
        y: number;
        width: number;
        height: number;
        coordinateSpace: "displayNormalizedTopLeft";
      }>;
    };
    change: {
      instruction: string;
      value: Nullable<string>;
    };
    constraints: string[];
    acceptanceCriteria: string[];
    evidence: Evidence[];
    confidence: number;
    assumptions: string[];
  }>;
  unresolvedQuestions: string[];
}

export interface ProgressEvent {
  type: "progress" | "complete" | "error";
  stage?: string;
  fraction?: number;
  taskSpecPath?: string;
  exportPath?: string;
  exportStatus?: "complete" | "failed";
  exportError?: ExportFailure;
  message?: string;
}

export interface ExportFailure {
  code: "permission" | "diskFull" | "readOnly" | "invalidDestination" | "unknown";
  message: string;
  retryable: boolean;
}
