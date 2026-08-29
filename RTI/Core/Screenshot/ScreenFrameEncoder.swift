import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscale + JPEG-encode a captured display image so a compact frame can be
/// kept in the session archive and shown to the local vision model, without
/// ever persisting full-resolution Retina bitmaps. 1,600px long edge at
/// quality 0.7 lands around 100–300 KB per frame.
public enum ScreenFrameEncoder {
    public static func jpegData(
        from image: CGImage,
        maxLongEdge: CGFloat = 1600,
        quality: CGFloat = 0.7
    ) -> Data? {
        let scaled = downscaled(image, maxLongEdge: maxLongEdge) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, scaled, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func downscaled(_ image: CGImage, maxLongEdge: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return image }
        let scale = maxLongEdge / longEdge
        let newWidth = max(1, Int((width * scale).rounded()))
        let newHeight = max(1, Int((height * scale).rounded()))
        let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }
}
