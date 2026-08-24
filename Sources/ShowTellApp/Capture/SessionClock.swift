import Foundation
import CoreMedia

final class SessionClock: @unchecked Sendable {
    let startUptimeNs: UInt64
    private let lock = NSLock()
    private var pausedAtNs: UInt64?
    private var totalPausedNs: UInt64 = 0
    private var frozenActiveNs: UInt64?

    init(startUptimeNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startUptimeNs = startUptimeNs
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return pausedAtNs != nil
    }

    func pause(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        guard frozenActiveNs == nil else { return }
        if pausedAtNs == nil { pausedAtNs = now }
    }

    func resume(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        guard frozenActiveNs == nil else { return }
        if let pausedAtNs {
            totalPausedNs += now - pausedAtNs
            self.pausedAtNs = nil
        }
    }

    func activeMilliseconds(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int {
        Int(activeNanoseconds(at: now) / 1_000_000)
    }

    func activeNanoseconds(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let frozenActiveNs { return frozenActiveNs }
        return activeNanosecondsLocked(at: now)
    }

    @discardableResult
    func freeze(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int {
        lock.lock(); defer { lock.unlock() }
        if frozenActiveNs == nil {
            frozenActiveNs = activeNanosecondsLocked(at: now)
        }
        return Int((frozenActiveNs ?? 0) / 1_000_000)
    }

    private func activeNanosecondsLocked(at now: UInt64) -> UInt64 {
        let effectiveNow = pausedAtNs ?? now
        let elapsed = effectiveNow >= startUptimeNs ? effectiveNow - startUptimeNs : 0
        return elapsed >= totalPausedNs ? elapsed - totalPausedNs : 0
    }

    func presentationTime(at now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> CMTime {
        // Millisecond truncation can assign the same PTS to multiple queued
        // ScreenCaptureKit frames when the framework delivers a burst. H.264
        // rejects non-increasing timestamps and the writer then drops every
        // remaining frame. Preserve the monotonic host-clock precision.
        CMTime(value: CMTimeValue(activeNanoseconds(at: now)), timescale: 1_000_000_000)
    }
}
