import Foundation

public struct PointValue: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct SizeValue: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct RectValue: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct DisplayDescriptor: Codable, Equatable, Sendable {
    public var id: UInt32
    public var framePoints: RectValue
    public var capturePixels: SizeValue
    public var pointPixelScale: Double

    public init(id: UInt32, framePoints: RectValue, capturePixels: SizeValue, pointPixelScale: Double) {
        self.id = id
        self.framePoints = framePoints
        self.capturePixels = capturePixels
        self.pointPixelScale = pointPixelScale
    }
}

public struct EventPosition: Codable, Equatable, Sendable {
    public var globalPoints: PointValue
    public var displayLocalPoints: PointValue
    public var displayNormalizedTopLeft: PointValue
    public var capturePixels: PointValue

    public init(
        globalPoints: PointValue,
        displayLocalPoints: PointValue,
        displayNormalizedTopLeft: PointValue,
        capturePixels: PointValue
    ) {
        self.globalPoints = globalPoints
        self.displayLocalPoints = displayLocalPoints
        self.displayNormalizedTopLeft = displayNormalizedTopLeft
        self.capturePixels = capturePixels
    }
}

public enum CoordinateMapper {
    public static func contains(globalTopLeft point: PointValue, display: DisplayDescriptor) -> Bool {
        let frame = display.framePoints
        return point.x >= frame.x && point.y >= frame.y &&
            point.x <= frame.x + frame.width && point.y <= frame.y + frame.height
    }

    public static func map(globalTopLeft point: PointValue, display: DisplayDescriptor) -> EventPosition {
        let frame = display.framePoints
        let localX = point.x - frame.x
        let localY = point.y - frame.y
        let normalizedX = clamp(localX / max(frame.width, 1))
        let normalizedY = clamp(localY / max(frame.height, 1))

        return EventPosition(
            globalPoints: point,
            displayLocalPoints: PointValue(x: localX, y: localY),
            displayNormalizedTopLeft: PointValue(x: normalizedX, y: normalizedY),
            capturePixels: PointValue(
                x: normalizedX * display.capturePixels.width,
                y: normalizedY * display.capturePixels.height
            )
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
