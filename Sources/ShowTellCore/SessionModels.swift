import Foundation

public enum SessionState: String, Codable, Sendable {
    case preparing
    case recording
    case finalizing
    /// Playable local media is finalized; TaskSpec processing is still optional/pending.
    case recorded
    case interrupted
    case recovering
    case processing
    case completed
    case failed
}

public struct ProjectContext: Codable, Equatable, Sendable {
    public var name: String?
    public var rootPath: String?
    public var gitBranch: String?
    public var headCommit: String?

    public init(name: String? = nil, rootPath: String? = nil, gitBranch: String? = nil, headCommit: String? = nil) {
        self.name = name
        self.rootPath = rootPath
        self.gitBranch = gitBranch
        self.headCommit = headCommit
    }
}

public struct CaptureArtifact: Codable, Equatable, Sendable {
    public var path: String
    public var startOffsetMs: Int

    public init(path: String, startOffsetMs: Int = 0) {
        self.path = path
        self.startOffsetMs = startOffsetMs
    }
}

public struct SessionArtifacts: Codable, Equatable, Sendable {
    public var recording: CaptureArtifact?
    public var microphone: CaptureArtifact?
    public var eventLog: CaptureArtifact
    public var frameIndex: CaptureArtifact
    public var transcript: CaptureArtifact?
    public var taskSpec: CaptureArtifact?

    public init(
        recording: CaptureArtifact? = nil,
        microphone: CaptureArtifact? = nil,
        eventLog: CaptureArtifact = .init(path: "events.ndjson"),
        frameIndex: CaptureArtifact = .init(path: "frames/index.json"),
        transcript: CaptureArtifact? = nil,
        taskSpec: CaptureArtifact? = nil
    ) {
        self.recording = recording
        self.microphone = microphone
        self.eventLog = eventLog
        self.frameIndex = frameIndex
        self.transcript = transcript
        self.taskSpec = taskSpec
    }
}

public struct PrivacyPolicy: Codable, Equatable, Sendable {
    public var recordsRawKeystrokesLocally: Bool
    public var recordsTypingActivityLocally: Bool
    public var recordsSafeShortcutsLocally: Bool
    public var evidenceFramesIncludeCamera: Bool
    public var uploadsRawKeystrokes: Bool
    public var uploadsRecordingFile: Bool
    public var safetyIdentifier: String

    public init(safetyIdentifier: String) {
        recordsRawKeystrokesLocally = false
        recordsTypingActivityLocally = true
        recordsSafeShortcutsLocally = true
        evidenceFramesIncludeCamera = false
        uploadsRawKeystrokes = false
        uploadsRecordingFile = false
        self.safetyIdentifier = safetyIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case recordsRawKeystrokesLocally
        case recordsTypingActivityLocally
        case recordsSafeShortcutsLocally
        case evidenceFramesIncludeCamera
        case uploadsRawKeystrokes
        case uploadsRecordingFile
        case safetyIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordsRawKeystrokesLocally = try container.decodeIfPresent(
            Bool.self,
            forKey: .recordsRawKeystrokesLocally
        ) ?? false
        recordsTypingActivityLocally = try container.decodeIfPresent(
            Bool.self,
            forKey: .recordsTypingActivityLocally
        ) ?? false
        recordsSafeShortcutsLocally = try container.decodeIfPresent(
            Bool.self,
            forKey: .recordsSafeShortcutsLocally
        ) ?? false
        // Sessions created before this flag existed captured evidence from the
        // composite writer and may contain the camera bubble.
        evidenceFramesIncludeCamera = try container.decodeIfPresent(
            Bool.self,
            forKey: .evidenceFramesIncludeCamera
        ) ?? true
        uploadsRawKeystrokes = try container.decodeIfPresent(
            Bool.self,
            forKey: .uploadsRawKeystrokes
        ) ?? false
        uploadsRecordingFile = try container.decodeIfPresent(
            Bool.self,
            forKey: .uploadsRecordingFile
        ) ?? false
        safetyIdentifier = try container.decode(String.self, forKey: .safetyIdentifier)
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var sessionId: String
    public var state: SessionState
    public var createdAt: String
    public var durationMs: Int?
    public var hostStartUptimeNs: UInt64
    public var captureMode: String?
    public var captureLabel: String?
    public var display: DisplayDescriptor
    public var cameraOverlayNormalizedTopLeft: RectValue
    public var project: ProjectContext
    public var artifacts: SessionArtifacts
    public var privacy: PrivacyPolicy
    public var errorMessage: String?
    public var recordingQuality: String?
    public var recoveredAt: String?
    public var diagnosticsConsent: Bool?

    public init(
        sessionId: String,
        state: SessionState,
        createdAt: String,
        hostStartUptimeNs: UInt64,
        captureMode: String? = nil,
        captureLabel: String? = nil,
        display: DisplayDescriptor,
        cameraOverlayNormalizedTopLeft: RectValue,
        project: ProjectContext,
        privacy: PrivacyPolicy
    ) {
        schemaVersion = "1.0"
        self.sessionId = sessionId
        self.state = state
        self.createdAt = createdAt
        durationMs = nil
        self.hostStartUptimeNs = hostStartUptimeNs
        self.captureMode = captureMode
        self.captureLabel = captureLabel
        self.display = display
        self.cameraOverlayNormalizedTopLeft = cameraOverlayNormalizedTopLeft
        self.project = project
        artifacts = SessionArtifacts()
        self.privacy = privacy
        errorMessage = nil
        recordingQuality = nil
        recoveredAt = nil
        diagnosticsConsent = nil
    }
}

public enum InputEventKind: String, Codable, Sendable {
    case mouseDown
    case mouseUp
    case mouseDragged
    case scroll
    case keyDown
    case keyUp
    case modifiersChanged
    case captureGap
}

public struct ActiveContext: Codable, Equatable, Sendable {
    public var appName: String?
    public var bundleIdentifier: String?
    public var windowTitle: String?

    public init(appName: String? = nil, bundleIdentifier: String? = nil, windowTitle: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
    }
}

public struct InputEvent: Codable, Equatable, Sendable {
    public var sequence: Int
    public var tMs: Int
    public var kind: InputEventKind
    public var position: EventPosition?
    public var mouseButton: String?
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?
    public var keyCode: Int?
    /// Legacy migration field. New captures always redact this value before
    /// the event crosses the capture boundary or reaches events.ndjson.
    public var characters: String?
    /// A privacy-reviewed shortcut label such as `command+c`. It is populated
    /// only for Command/Control shortcuts and non-text control keys.
    public var shortcut: String?
    public var modifiers: [String]
    public var context: ActiveContext
    public var reason: String?

    public init(
        sequence: Int,
        tMs: Int,
        kind: InputEventKind,
        position: EventPosition? = nil,
        mouseButton: String? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        keyCode: Int? = nil,
        characters: String? = nil,
        shortcut: String? = nil,
        modifiers: [String] = [],
        context: ActiveContext = .init(),
        reason: String? = nil
    ) {
        self.sequence = sequence
        self.tMs = tMs
        self.kind = kind
        self.position = position
        self.mouseButton = mouseButton
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.keyCode = keyCode
        self.characters = characters
        self.shortcut = shortcut
        self.modifiers = modifiers
        self.context = context
        self.reason = reason
    }
}

public enum FrameKind: String, Codable, Sendable {
    case first
    case last
    case click
    case afterClick
    case scrollSettled
    case typingSettled
    case periodic
}

public struct FrameCandidate: Codable, Equatable, Sendable {
    public var file: String
    public var tMs: Int
    public var kind: FrameKind
    public var clickPosition: PointValue?

    public init(file: String, tMs: Int, kind: FrameKind, clickPosition: PointValue? = nil) {
        self.file = file
        self.tMs = tMs
        self.kind = kind
        self.clickPosition = clickPosition
    }
}

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var word: String
    public var start: Double
    public var end: Double
}

public struct TranscriptDocument: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?
    public var words: [TranscriptWord]
}

public struct TaskSpec: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var sessionId: String
    public var project: ProjectContext
    public var goal: String
    public var summary: String
    public var tasks: [Task]
    public var unresolvedQuestions: [String]

    public struct Task: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var target: Target
        public var change: Change
        public var constraints: [String]
        public var acceptanceCriteria: [String]
        public var evidence: [Evidence]
        public var confidence: Double
        public var assumptions: [String]
    }

    public struct Target: Codable, Equatable, Sendable {
        public var description: String
        public var app: String?
        public var windowTitle: String?
        public var region: NormalizedRegion?
    }

    public struct NormalizedRegion: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var coordinateSpace: String
    }

    public struct Change: Codable, Equatable, Sendable {
        public var instruction: String
        public var value: String?
    }

    public struct Evidence: Codable, Equatable, Sendable {
        public var kind: String
        public var tMs: Int
        public var frame: String?
        public var quote: String?
        public var position: NormalizedPosition?
    }

    public struct NormalizedPosition: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var coordinateSpace: String
    }
}
