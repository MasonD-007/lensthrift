import CoreImage
import UIKit

/// Writes captures as JPEG into Documents/captures (visible in the Files app).
///
/// JPEG is what SAM 3's examples load and what a backend upload will send, so
/// every capture path ends here. Swap `save` for an upload when the backend exists.
struct CaptureStore {
    struct Saved {
        let url: URL
        let pixelSize: CGSize
    }

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let ciContext = CIContext()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    static func save(pixelBuffer: CVPixelBuffer, tag: String) throws -> Saved {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let data = ciContext.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try save(jpeg: data, size: image.extent.size, tag: tag)
    }

    /// The centered square of a frame, scaled to `side` px, as JPEG. Matches what the web client sends to YOLO.
    static func squareJPEG(pixelBuffer: CVPixelBuffer, side: CGFloat, quality: CGFloat = 0.7) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let s = min(extent.width, extent.height)
        let crop = CGRect(x: extent.midX - s / 2, y: extent.midY - s / 2, width: s, height: s)
        let scaled = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: side / s, y: side / s))
        return ciContext.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }

    static func save(jpeg data: Data, tag: String) throws -> Saved {
        let size = UIImage(data: data)?.pixelSize ?? .zero
        return try save(jpeg: data, size: size, tag: tag)
    }

    /// Recovers the capture time from a file name written by `save`.
    static func date(from url: URL) -> Date? {
        formatter.date(from: String(url.lastPathComponent.prefix(19)))
    }

    static func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    private static func save(jpeg data: Data, size: CGSize, tag: String) throws -> Saved {
        let url = directory.appendingPathComponent("\(formatter.string(from: Date()))-\(tag).jpg")
        try data.write(to: url, options: .atomic)
        return Saved(url: url, pixelSize: size)
    }
}

private extension UIImage {
    var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}
