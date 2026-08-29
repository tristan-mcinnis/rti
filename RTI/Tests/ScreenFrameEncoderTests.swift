import CoreGraphics
import ImageIO
@testable import RTICore
import XCTest

final class ScreenFrameEncoderTests: XCTestCase {
    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func decodedSize(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    func testEncodesJPEGAndDownscalesLongEdge() throws {
        let image = try solidImage(width: 3200, height: 1800)
        let data = try XCTUnwrap(ScreenFrameEncoder.jpegData(from: image, maxLongEdge: 1600))
        XCTAssertEqual([UInt8](data.prefix(2)), [0xFF, 0xD8], "JPEG magic bytes expected")
        let size = try decodedSize(of: data)
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 900)
    }

    func testSmallImagesAreNotUpscaled() throws {
        let image = try solidImage(width: 200, height: 100)
        let data = try XCTUnwrap(ScreenFrameEncoder.jpegData(from: image, maxLongEdge: 1600))
        let size = try decodedSize(of: data)
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 100)
    }
}
