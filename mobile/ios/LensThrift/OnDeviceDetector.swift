import CoreImage
import CoreML
import Vision

/// YOLO11n on the phone with Core ML, so detection needs no network.
///
/// Same model and input size as the backend's `/api/detect` (yolo11n, 320px, conf 0.3), run on
/// the frame's center square, so boxes come back normalized to that square exactly like the
/// backend's do and the overlay, stabilizer and crops work unchanged.
final class OnDeviceDetector: @unchecked Sendable {
    static let inputSide = 320
    static let minConfidence: Float = 0.3

    private let request: VNCoreMLRequest
    private let ciContext = CIContext()
    private let lock = NSLock()

    init(modelURL: URL? = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc")) throws {
        guard let url = modelURL else { throw CocoaError(.fileNoSuchFile) }
        let config = MLModelConfiguration()
        config.computeUnits = .all // Neural Engine when available
        let model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
        request = VNCoreMLRequest(model: model)
        // We hand it an exact 320x320 square, so no further cropping or letterboxing.
        request.imageCropAndScaleOption = .scaleFill
    }

    /// Detections in the center square of `frame`, boxes as [x1, y1, x2, y2] normalized 0–1, top-left origin.
    func detect(_ frame: CVPixelBuffer) throws -> [Detection] {
        guard let square = makeSquare(frame) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        try VNImageRequestHandler(cvPixelBuffer: square, orientation: .up).perform([request])
        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return observations.compactMap { obs in
            guard let top = obs.labels.first, top.confidence >= Self.minConfidence else { return nil }
            let r = obs.boundingBox // normalized, bottom-left origin
            return Detection(label: top.identifier, conf: Double(top.confidence),
                             box: [r.minX, 1 - r.maxY, r.maxX, 1 - r.minY].map(Double.init))
        }
    }

    /// The frame's centered square scaled to 320x320, as a new pixel buffer.
    private func makeSquare(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: frame)
        let e = image.extent
        let s = min(e.width, e.height)
        let side = CGFloat(Self.inputSide)
        let square = image
            .cropped(to: CGRect(x: e.midX - s / 2, y: e.midY - s / 2, width: s, height: s))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - s / 2), y: -(e.midY - s / 2)))
            .transformed(by: CGAffineTransform(scaleX: side / s, y: side / s))
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, Self.inputSide, Self.inputSide, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
        guard let out else { return nil }
        ciContext.render(square, to: out)
        return out
    }
}
