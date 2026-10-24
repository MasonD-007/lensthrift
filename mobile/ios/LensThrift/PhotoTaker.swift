import AVFoundation

/// Native still capture on the same AVCaptureSession HaishinKit runs.
final class PhotoTaker: NSObject, @unchecked Sendable {
    let output = AVCapturePhotoOutput()
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    private let lock = NSLock()

    enum Failure: Error {
        case noData
    }

    /// Asks for the largest still the active camera format supports.
    func configure(for device: AVCaptureDevice) {
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            output.maxPhotoDimensions = largest
        }
        output.maxPhotoQualityPrioritization = .balanced
    }

    func capture() async throws -> Data {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.photoQualityPrioritization = .balanced
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[settings.uniqueID] = continuation
            lock.unlock()
            output.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension PhotoTaker: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock()
        let continuation = pending.removeValue(forKey: photo.resolvedSettings.uniqueID)
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            continuation?.resume(returning: data)
        } else {
            continuation?.resume(throwing: Failure.noData)
        }
    }
}
