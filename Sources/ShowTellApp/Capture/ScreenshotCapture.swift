import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotCapture {
    static func capture(source: SelectedDisplaySource, exportDirectory: URL) async throws -> URL {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(source.descriptor.capturePixels.width)
        configuration.height = Int(source.descriptor.capturePixels.height)
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        if let sourceRect = source.sourceRect { configuration.sourceRect = sourceRect }

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: source.filter,
            configuration: configuration
        )
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "SOOM Screenshot \(formatter.string(from: Date()))"
        let destination = collisionFreeURL(base: base, directory: exportDirectory)
        let temporary = destination.appendingPathExtension("tmp")

        guard let target = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw ScreenshotError.cannotCreateFile }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw ScreenshotError.cannotEncode }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    private static func collisionFreeURL(base: String, directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("png")
            suffix += 1
        }
        return candidate
    }
}

enum ScreenshotError: LocalizedError {
    case cannotCreateFile
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile: return "스크린샷 파일을 만들 수 없습니다."
        case .cannotEncode: return "스크린샷을 PNG로 저장할 수 없습니다."
        }
    }
}
