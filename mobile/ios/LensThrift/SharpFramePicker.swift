import AVFoundation
import CoreMotion
import HaishinKit

/// Watches HaishinKit's raw camera track and remembers the sharpest frame since the last `takeBest()`.
///
/// Track 0 is the camera input before any mixing, so frames arrive at the full
/// session preset size (1080x1920 in portrait with `.hd1920x1080`).
///
/// To stay light on the phone it scores only every `stride`-th frame, on a small
/// center crop of the luma plane, on its own queue, and drops frames while busy.
/// Only one frame is ever held, and nothing is encoded until the caller asks.
final class SharpFramePicker: MediaMixerOutput, @unchecked Sendable {
    struct Pick {
        let pixelBuffer: CVPixelBuffer
        /// Higher is sharper. Laplacian variance, discounted by how fast the phone was turning.
        let score: Double
    }

    /// Score every 3rd frame: about 10 candidates a second at 30 fps.
    private let stride = 3
    /// Side of the square center crop that gets scored, in pixels.
    private let cropSide = 256

    private let queue = DispatchQueue(label: "SharpFramePicker", qos: .userInitiated)
    private let lock = NSLock()
    private var best: Pick?
    private var latest: CVPixelBuffer?
    private var frameCount = 0
    private var isScoring = false
    private var scoringEnabled = true
    private let motion = CMMotionManager()

    var videoTrackId: UInt8? { 0 }
    var audioTrackId: UInt8? { nil }

    func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        // Polled from `score`, so no handler or extra queue is needed.
        motion.startDeviceMotionUpdates()
    }

    func stopMotion() {
        motion.stopDeviceMotionUpdates()
    }

    /// Turns sharpness scoring on or off. Off, the picker only keeps the newest frame (almost free).
    func setScoringEnabled(_ enabled: Bool) {
        lock.lock()
        scoringEnabled = enabled
        if !enabled { best = nil }
        lock.unlock()
    }

    /// The newest camera frame, or nil before the first one arrives.
    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Returns the sharpest frame seen since the last call, falling back to the newest frame, and starts a new window.
    func takeBest() -> Pick? {
        lock.lock()
        defer { lock.unlock() }
        let pick = best ?? latest.map { Pick(pixelBuffer: $0, score: 0) }
        best = nil
        return pick
    }

    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = pixelBuffer
        frameCount += 1
        let shouldScore = scoringEnabled && frameCount % stride == 0 && !isScoring
        if shouldScore { isScoring = true }
        lock.unlock()
        guard shouldScore else { return }

        // Score off HaishinKit's delivery path so the preview never waits on us.
        queue.async { [self] in
            let score = score(pixelBuffer)
            lock.lock()
            if score > (best?.score ?? -1) {
                best = Pick(pixelBuffer: pixelBuffer, score: score)
            }
            isScoring = false
            lock.unlock()
        }
    }

    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}

    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}

    private func score(_ pixelBuffer: CVPixelBuffer) -> Double {
        let sharpness = laplacianVariance(pixelBuffer)
        // Rotation in rad/s; walking sway is roughly 0.2 to 1. Fast turns smear the image.
        let rate = motion.deviceMotion?.rotationRate
        let turning = rate.map { sqrt($0.x * $0.x + $0.y * $0.y + $0.z * $0.z) } ?? 0
        return sharpness / (1 + 2 * turning)
    }

    /// Variance of the Laplacian over a center crop of the luma plane. Blurry images score low.
    private func laplacianVariance(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // HaishinKit captures 420YpCbCr bi-planar, so plane 0 is 8-bit luma.
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let base = planar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return 0 }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        // Non-planar formats are 4 bytes per pixel; sampling one channel is close enough to luma.
        let pixelBytes = planar ? 1 : 4

        let side = min(cropSide, width - 2, height - 2)
        guard side > 2 else { return 0 }
        let x0 = (width - side) / 2
        let y0 = (height - side) / 2
        let p = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0.0
        var sumSquares = 0.0
        for y in y0..<(y0 + side) {
            let row = p + y * rowBytes
            let up = row - rowBytes
            let down = row + rowBytes
            for x in x0..<(x0 + side) {
                let i = x * pixelBytes
                let lap = 4 * Int(row[i]) - Int(row[i - pixelBytes]) - Int(row[i + pixelBytes]) - Int(up[i]) - Int(down[i])
                let v = Double(lap)
                sum += v
                sumSquares += v * v
            }
        }
        let n = Double(side * side)
        let mean = sum / n
        return sumSquares / n - mean * mean
    }
}
