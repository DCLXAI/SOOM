import ShowTellCore
import Testing

@Suite("Offline-first recording policy")
struct LocalRecordingPolicyTests {
    @Test("an API key is never required to preserve finalized media")
    func apiKeylessRecordingRemainsRecorded() {
        let plan = LocalRecordingPolicy.finalizationPlan(
            taskSpecRequested: true,
            hasAPIKey: false
        )

        #expect(plan.persistedState == .recorded)
        #expect(!plan.shouldProcessTaskSpec)
    }

    @Test("TaskSpec processing starts only when explicitly requested with BYOK")
    func taskSpecRequiresRequestAndKey() {
        #expect(!LocalRecordingPolicy.finalizationPlan(
            taskSpecRequested: false,
            hasAPIKey: true
        ).shouldProcessTaskSpec)
        #expect(LocalRecordingPolicy.finalizationPlan(
            taskSpecRequested: true,
            hasAPIKey: true
        ).shouldProcessTaskSpec)
    }

    @Test("screen and microphone are the only unconditional recording grants")
    func corePermissionBoundary() {
        let snapshot = RecordingPermissionSnapshot(
            screenCaptureGranted: true,
            microphoneGranted: true,
            cameraGranted: false,
            inputMonitoringGranted: false
        )

        let cameraOff = LocalRecordingPolicy.permissions(snapshot, cameraRequired: false)
        let cameraOn = LocalRecordingPolicy.permissions(snapshot, cameraRequired: true)

        #expect(cameraOff.canRecord)
        #expect(cameraOff.missing.isEmpty)
        #expect(!cameraOn.canRecord)
        #expect(cameraOn.missing == [.camera])
    }

    @Test("Input Monitoring enriches evidence but never gates media capture")
    func inputMonitoringIsOptional() {
        let denied = RecordingPermissionSnapshot(
            screenCaptureGranted: true,
            microphoneGranted: true,
            cameraGranted: true,
            inputMonitoringGranted: false
        )
        let granted = RecordingPermissionSnapshot(
            screenCaptureGranted: true,
            microphoneGranted: true,
            cameraGranted: true,
            inputMonitoringGranted: true
        )

        #expect(LocalRecordingPolicy.permissions(denied, cameraRequired: true).canRecord)
        #expect(LocalRecordingPolicy.permissions(granted, cameraRequired: true).canRecord)
    }

    @Test("missing grants are reported in a stable user-facing order")
    func missingPermissionOrder() {
        let snapshot = RecordingPermissionSnapshot(
            screenCaptureGranted: false,
            microphoneGranted: false,
            cameraGranted: false,
            inputMonitoringGranted: false
        )

        #expect(LocalRecordingPolicy.permissions(snapshot, cameraRequired: true).missing == [
            .screenCapture,
            .microphone,
            .camera
        ])
    }

    @Test("Quit waits for media but never waits for optional TaskSpec processing")
    func safeTerminationActions() {
        #expect(LocalRecordingPolicy.terminationAction(for: .inactive) == .terminateImmediately)
        #expect(LocalRecordingPolicy.terminationAction(for: .capturing) == .requestRecordingFinalization)
        #expect(LocalRecordingPolicy.terminationAction(for: .finalizing) == .awaitRecordingFinalization)
        #expect(
            LocalRecordingPolicy.terminationAction(for: .processingTaskSpec)
                == .cancelTaskSpecProcessingAndTerminate
        )
        #expect(LocalRecordingPolicy.terminationAction(for: .mediaSaved) == .terminateImmediately)
    }

    @Test("only finalized local media is safe at the termination boundary")
    func safePersistedStates() {
        #expect(LocalRecordingPolicy.mediaIsSafeForTermination(sessionState: .recorded))
        #expect(LocalRecordingPolicy.mediaIsSafeForTermination(sessionState: .completed))
        #expect(!LocalRecordingPolicy.mediaIsSafeForTermination(sessionState: .recording))
        #expect(!LocalRecordingPolicy.mediaIsSafeForTermination(sessionState: .finalizing))
        #expect(!LocalRecordingPolicy.mediaIsSafeForTermination(sessionState: .failed))
    }
}
