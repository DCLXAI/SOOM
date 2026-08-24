import Testing
@testable import ShowTellCore

@Suite struct CoordinateMapperTests {
    @Test func mapsRetinaDisplayCoordinates() {
        let display = DisplayDescriptor(
            id: 7,
            framePoints: RectValue(x: 1440, y: 0, width: 1440, height: 900),
            capturePixels: SizeValue(width: 2560, height: 1600),
            pointPixelScale: 2
        )

        let mapped = CoordinateMapper.map(globalTopLeft: PointValue(x: 2160, y: 450), display: display)

        #expect(mapped.displayLocalPoints == PointValue(x: 720, y: 450))
        #expect(abs(mapped.displayNormalizedTopLeft.x - 0.5) < 0.0001)
        #expect(abs(mapped.displayNormalizedTopLeft.y - 0.5) < 0.0001)
        #expect(mapped.capturePixels == PointValue(x: 1280, y: 800))
    }

    @Test func clampsPointerOutsideSelectedDisplay() {
        let display = DisplayDescriptor(
            id: 1,
            framePoints: RectValue(x: 0, y: 0, width: 100, height: 100),
            capturePixels: SizeValue(width: 200, height: 200),
            pointPixelScale: 2
        )

        let mapped = CoordinateMapper.map(globalTopLeft: PointValue(x: -20, y: 150), display: display)

        #expect(mapped.displayNormalizedTopLeft == PointValue(x: 0, y: 1))
        #expect(mapped.capturePixels == PointValue(x: 0, y: 200))
        #expect(!CoordinateMapper.contains(
            globalTopLeft: PointValue(x: -20, y: 150),
            display: display
        ))
        #expect(CoordinateMapper.contains(
            globalTopLeft: PointValue(x: 50, y: 50),
            display: display
        ))
    }
}
