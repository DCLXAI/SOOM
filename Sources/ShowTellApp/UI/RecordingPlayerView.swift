import AVFoundation
import AVKit
import SwiftUI

/// AppKit-backed recording playback view.
///
/// SwiftUI's `VideoPlayer` uses the private `_AVKit_SwiftUI.VideoPlayerView`
/// subclass. That subclass currently aborts while resolving its AVPlayerView
/// superclass on the supported macOS runtime, so keep playback on the public
/// AppKit API instead.
struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Void) {
        nsView.player = nil
    }
}
