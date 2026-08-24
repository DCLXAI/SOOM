import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import ShowTellCore
import UniformTypeIdentifiers

final class FrameCaptureManager: @unchecked Sendable {
    private struct PendingCapture {
        let dueMs: Int
        let kind: FrameKind
        let clickPosition: PointValue?
    }

    private let framesDirectory: URL
    private let queue = DispatchQueue(label: "com.showtellai.keyframes")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latestBuffer: CVPixelBuffer?
    private var pending: [PendingCapture] = []
    private var candidates: [FrameCandidate] = []
    private var capturedFirst = false
    private var nextPeriodicMs = 5_000
    private var sequence = 0

    init(framesDirectory: URL) {
        self.framesDirectory = framesDirectory
    }

    func request(kind: FrameKind, at dueMs: Int, clickPosition: PointValue? = nil) {
        queue.async {
            guard self.candidates.count + self.pending.count < 100 else { return }
            self.pending.append(PendingCapture(dueMs: dueMs, kind: kind, clickPosition: clickPosition))
            self.pending.sort { $0.dueMs < $1.dueMs }
        }
    }

    func consume(_ buffer: CVPixelBuffer, at tMs: Int) {
        queue.async {
            self.latestBuffer = buffer
            if !self.capturedFirst {
                self.capturedFirst = true
                self.save(buffer, tMs: tMs, kind: .first, clickPosition: nil)
            }
            while tMs >= self.nextPeriodicMs {
                self.save(buffer, tMs: tMs, kind: .periodic, clickPosition: nil)
                self.nextPeriodicMs += 5_000
            }
            let ready = self.pending.filter { $0.dueMs <= tMs }
            self.pending.removeAll { $0.dueMs <= tMs }
            for item in ready {
                self.save(buffer, tMs: tMs, kind: item.kind, clickPosition: item.clickPosition)
            }
        }
    }

    func finish(at tMs: Int) async -> [FrameCandidate] {
        await withCheckedContinuation { continuation in
            queue.async {
                if let buffer = self.latestBuffer {
                    self.save(buffer, tMs: tMs, kind: .last, clickPosition: nil)
                }
                continuation.resume(returning: self.candidates.sorted { $0.tMs < $1.tMs })
            }
        }
    }

    private func save(_ buffer: CVPixelBuffer, tMs: Int, kind: FrameKind, clickPosition: PointValue?) {
        guard candidates.count < 100 else { return }
        let input = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(input, from: input.extent) else { return }

        sequence += 1
        let name = String(format: "%03d-%06d-%@.jpg", sequence, max(0, tMs), kind.rawValue)
        let destinationURL = framesDirectory.appendingPathComponent(name)
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return }

        let rendered = clickPosition.flatMap { markedImage(cgImage, at: $0) } ?? cgImage
        CGImageDestinationAddImage(
            destination,
            rendered,
            [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            try (mutable as Data).write(to: destinationURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            candidates.append(
                FrameCandidate(
                    file: "frames/\(name)",
                    tMs: tMs,
                    kind: kind,
                    clickPosition: clickPosition
                )
            )
        } catch {
            return
        }
    }

    private func markedImage(_ image: CGImage, at normalizedTopLeft: PointValue) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let point = CGPoint(
            x: normalizedTopLeft.x * Double(width),
            y: (1 - normalizedTopLeft.y) * Double(height)
        )
        let radius = max(14, min(CGFloat(width), CGFloat(height)) * 0.018)
        context.setFillColor(CGColor(red: 1, green: 0.24, blue: 0.16, alpha: 0.18))
        context.fillEllipse(in: CGRect(x: point.x - radius * 1.5, y: point.y - radius * 1.5, width: radius * 3, height: radius * 3))
        context.setStrokeColor(CGColor(red: 1, green: 0.24, blue: 0.16, alpha: 1))
        context.setLineWidth(max(4, radius * 0.22))
        context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        return context.makeImage()
    }
}
