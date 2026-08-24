import Foundation

/// A framework-independent snapshot of the macOS privacy grants that affect
/// local recording. Input Monitoring is deliberately represented but never
/// required: it enriches the event timeline and must not block media capture.
public struct RecordingPermissionSnapshot: Equatable, Sendable {
    public var screenCaptureGranted: Bool
    public var microphoneGranted: Bool
    public var cameraGranted: Bool
    public var inputMonitoringGranted: Bool

    public init(
        screenCaptureGranted: Bool,
        microphoneGranted: Bool,
        cameraGranted: Bool,
        inputMonitoringGranted: Bool
    ) {
        self.screenCaptureGranted = screenCaptureGranted
        self.microphoneGranted = microphoneGranted
        self.cameraGranted = cameraGranted
        self.inputMonitoringGranted = inputMonitoringGranted
    }
}

public enum RequiredRecordingPermission: String, Equatable, Sendable {
    case screenCapture
    case microphone
    case camera
}

public struct RecordingPermissionDecision: Equatable, Sendable {
    public let missing: [RequiredRecordingPermission]

    public var canRecord: Bool { missing.isEmpty }

    public init(missing: [RequiredRecordingPermission]) {
        self.missing = missing
    }
}

public struct LocalRecordingFinalizationPlan: Equatable, Sendable {
    /// Media is persisted before any optional network-backed processing.
    public let persistedState: SessionState
    public let shouldProcessTaskSpec: Bool

    public init(persistedState: SessionState, shouldProcessTaskSpec: Bool) {
        self.persistedState = persistedState
        self.shouldProcessTaskSpec = shouldProcessTaskSpec
    }
}

public enum LocalRecordingLifecyclePhase: Equatable, Sendable {
    case inactive
    case capturing
    case finalizing
    /// TaskSpec generation happens only after local media is finalized.
    case processingTaskSpec
    case mediaSaved
}

public enum RecordingTerminationAction: Equatable, Sendable {
    case terminateImmediately
    case requestRecordingFinalization
    case awaitRecordingFinalization
    case cancelTaskSpecProcessingAndTerminate
}

/// Pure product-boundary decisions shared by UI code and regression tests.
/// Keeping these rules outside AppKit makes the offline-first contract explicit:
/// a missing API key can disable TaskSpec generation, but never recording.
public enum LocalRecordingPolicy {
    public static func permissions(
        _ snapshot: RecordingPermissionSnapshot,
        cameraRequired: Bool
    ) -> RecordingPermissionDecision {
        var missing: [RequiredRecordingPermission] = []
        if !snapshot.screenCaptureGranted { missing.append(.screenCapture) }
        if !snapshot.microphoneGranted { missing.append(.microphone) }
        if cameraRequired, !snapshot.cameraGranted { missing.append(.camera) }
        return RecordingPermissionDecision(missing: missing)
    }

    public static func finalizationPlan(
        taskSpecRequested: Bool,
        hasAPIKey: Bool
    ) -> LocalRecordingFinalizationPlan {
        LocalRecordingFinalizationPlan(
            persistedState: .recorded,
            shouldProcessTaskSpec: taskSpecRequested && hasAPIKey
        )
    }

    public static func terminationAction(
        for phase: LocalRecordingLifecyclePhase
    ) -> RecordingTerminationAction {
        switch phase {
        case .inactive, .mediaSaved:
            return .terminateImmediately
        case .capturing:
            return .requestRecordingFinalization
        case .finalizing:
            return .awaitRecordingFinalization
        case .processingTaskSpec:
            return .cancelTaskSpecProcessingAndTerminate
        }
    }

    public static func mediaIsSafeForTermination(sessionState: SessionState) -> Bool {
        sessionState == .recorded || sessionState == .completed
    }
}
