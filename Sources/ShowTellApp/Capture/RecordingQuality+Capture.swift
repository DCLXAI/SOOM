import CoreGraphics
import ShowTellCore

extension RecordingQuality {
    var maximumDimensions: CGSize {
        switch self {
        case .standard1080p: return CGSize(width: 1_920, height: 1_080)
        case .ultra4K: return CGSize(width: 3_840, height: 2_160)
        }
    }

    var averageVideoBitRate: Int {
        switch self {
        case .standard1080p: return 8_000_000
        case .ultra4K: return 24_000_000
        }
    }

    func outputSize(for source: CGSize) -> CGSize {
        // Use the hardware encoder's standard canvas. Arbitrary aspect-derived
        // sizes such as 1660x1080 can fail at a later GOP boundary even though
        // AVAssetWriter initially accepts them. ScreenCaptureKit preserves the
        // selected source's aspect ratio inside this canvas.
        maximumDimensions
    }
}
