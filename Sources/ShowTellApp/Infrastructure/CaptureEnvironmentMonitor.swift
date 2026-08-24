import AppKit
import AVFoundation
import Foundation

enum CaptureEnvironmentEvent: Sendable {
    case cameraDisconnected
    case cameraConnected
    case microphoneDisconnected
    case displayConfigurationChanged
    case displayDisconnected
    case systemWillSleep
    case systemDidWake
}

@MainActor
final class CaptureEnvironmentMonitor {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displayID: UInt32?
    private var microphoneDeviceID: String?
    private var onEvent: ((CaptureEnvironmentEvent) -> Void)?

    func start(
        displayID: UInt32,
        microphoneDeviceID: String?,
        onEvent: @escaping (CaptureEnvironmentEvent) -> Void
    ) {
        stop()
        self.displayID = displayID
        self.microphoneDeviceID = microphoneDeviceID
        self.onEvent = onEvent

        observe(NotificationCenter.default, name: NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            guard let self, let displayID = self.displayID else { return }
            let remainsConnected = NSScreen.screens.contains { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }
            self.onEvent?(remainsConnected ? .displayConfigurationChanged : .displayDisconnected)
        }
        observe(NotificationCenter.default, name: AVCaptureDevice.wasDisconnectedNotification) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice else { return }
            if device.hasMediaType(.audio),
               self.microphoneDeviceID == nil || device.uniqueID == self.microphoneDeviceID {
                self.onEvent?(.microphoneDisconnected)
            }
            if device.hasMediaType(.video) { self.onEvent?(.cameraDisconnected) }
        }
        observe(NotificationCenter.default, name: AVCaptureDevice.wasConnectedNotification) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
            self?.onEvent?(.cameraConnected)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(workspaceCenter, name: NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.onEvent?(.systemWillSleep)
        }
        observe(workspaceCenter, name: NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.onEvent?(.systemDidWake)
        }
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        displayID = nil
        microphoneDeviceID = nil
        onEvent = nil
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated { handler(notification) }
        }
        observers.append((center, token))
    }
}
