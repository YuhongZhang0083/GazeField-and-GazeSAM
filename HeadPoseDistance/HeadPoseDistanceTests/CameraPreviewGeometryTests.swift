import XCTest
import CoreImage
@testable import HeadPoseDistance

/// Pure geometry used by the live camera preview: portrait rotation, selfie
/// mirroring, and aspect-fill placement.
final class CameraPreviewGeometryTests: XCTestCase {

    /// A landscape "camera" image, 640x480, like the front capture buffer.
    private let source = CIImage(color: .gray)
        .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))

    func testPortraitOrientationSwapsWidthAndHeight() {
        let result = CameraPreviewRenderer.orientedForPortraitSelfie(source)
        XCTAssertEqual(result.extent.width, 480, accuracy: 0.001)
        XCTAssertEqual(result.extent.height, 640, accuracy: 0.001)
    }

    /// Mirroring must not push the image off its own origin, otherwise the
    /// aspect-fill maths would centre the wrong region.
    func testMirroredImageKeepsOriginAtZero() {
        let result = CameraPreviewRenderer.orientedForPortraitSelfie(source)
        XCTAssertEqual(result.extent.minX, 0, accuracy: 0.001)
        XCTAssertEqual(result.extent.minY, 0, accuracy: 0.001)
    }

    /// Samples the red channel of a single pixel.
    private func redChannel(_ image: CIImage, x: CGFloat, y: CGFloat) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(image,
                           toBitmap: &pixel,
                           rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixel[0]
    }

    func testPreviewIsHorizontallyMirrored() {
        // A horizontal band in the landscape source becomes a *vertical* band
        // once rotated to portrait, which is what makes this test sensitive to
        // a horizontal flip.
        let marked = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 64))
            .composited(over: source)

        let rotatedOnly = marked.oriented(.right)
        let mirrored = CameraPreviewRenderer.orientedForPortraitSelfie(marked)

        let midY = rotatedOnly.extent.midY
        let leftX = rotatedOnly.extent.minX + 2
        let rightX = rotatedOnly.extent.maxX - 2

        // Guard: the rotated image must be horizontally asymmetric, otherwise
        // the mirror assertions below would pass vacuously.
        let rotatedLeft = redChannel(rotatedOnly, x: leftX, y: midY)
        let rotatedRight = redChannel(rotatedOnly, x: rightX, y: midY)
        XCTAssertNotEqual(rotatedLeft, rotatedRight,
                          "test fixture must be asymmetric after rotation")

        // The mirrored preview swaps the two sides.
        XCTAssertEqual(redChannel(mirrored, x: leftX, y: midY), rotatedRight)
        XCTAssertEqual(redChannel(mirrored, x: rightX, y: midY), rotatedLeft)
    }

    func testAspectFillCoversTargetWithoutLetterboxing() {
        let portrait = CameraPreviewRenderer.orientedForPortraitSelfie(source) // 480x640
        let target = CGSize(width: 1179, height: 2556)                          // iPhone-ish
        let filled = CameraPreviewRenderer.aspectFill(portrait, into: target)

        XCTAssertLessThanOrEqual(filled.extent.minX, 0.001)
        XCTAssertLessThanOrEqual(filled.extent.minY, 0.001)
        XCTAssertGreaterThanOrEqual(filled.extent.maxX, target.width - 0.001)
        XCTAssertGreaterThanOrEqual(filled.extent.maxY, target.height - 0.001)
    }

    func testAspectFillPreservesAspectRatio() {
        let portrait = CameraPreviewRenderer.orientedForPortraitSelfie(source)
        let sourceRatio = portrait.extent.width / portrait.extent.height
        let filled = CameraPreviewRenderer.aspectFill(portrait,
                                                      into: CGSize(width: 1000, height: 500))
        XCTAssertEqual(filled.extent.width / filled.extent.height, sourceRatio, accuracy: 0.001)
    }

    func testAspectFillCentersOverflow() {
        let portrait = CameraPreviewRenderer.orientedForPortraitSelfie(source) // 480x640
        let target = CGSize(width: 480, height: 320)
        let filled = CameraPreviewRenderer.aspectFill(portrait, into: target)
        // Overflow is vertical here and must be split evenly above and below.
        XCTAssertEqual(filled.extent.minY, target.height - filled.extent.maxY, accuracy: 0.001)
    }

    func testAspectFillIgnoresDegenerateTarget() {
        let portrait = CameraPreviewRenderer.orientedForPortraitSelfie(source)
        let result = CameraPreviewRenderer.aspectFill(portrait, into: .zero)
        XCTAssertEqual(result.extent, portrait.extent)
    }
}
