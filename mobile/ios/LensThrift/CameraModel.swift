import AVFoundation
import HaishinKit
import UIKit

/// Owns the HaishinKit pipeline and turns it into one clear still per second.
@MainActor
final class CameraModel: ObservableObject {
    /// Where a still comes from. Not shown in the UI; `.sharpestFrame` is the default.
    enum Source {
        /// The sharpest live frame of the last second (1080x1920). Cheap, no shutter.
        case sharpestFrame
        /// A native AVCapturePhotoOutput still. Sharper processing, more work per shot. Kept in case it's needed.
        case photo
    }

    var source: Source = .sharpestFrame

    @Published private(set) var isLive = false
    @Published private(set) var cameraAvailable = true
    @Published private(set) var status = "Starting camera…"
    @Published private(set) var lastSize: CGSize?
    @Published private(set) var lastScore: Double?
    @Published private(set) var savedCount = CaptureStore.count()
    /// YOLO boxes for the latest detect call, normalized to the frame's center square.
    @Published private(set) var detections: [Detection] = []
    /// Pixel size of the frame the boxes belong to, for mapping them onto the preview.
    @Published private(set) var detectFrameSize: CGSize?
    @Published private(set) var detectLatencyMs: Int?
    /// Detect replies per second over the last 2 s, to compare with the web page.
    @Published private(set) var detectRate: Double?
    private var detectTimes: [ContinuousClock.Instant] = []
    @Published private(set) var backendError: String?
    /// Which object is being held steady before it's priced (see `Stabilizer`).
    @Published private(set) var scan = Stabilizer.Scan(phase: .searching, target: nil, progress: 0)
    /// What the pipeline last said, or why it stayed quiet.
    @Published private(set) var lastReply: String?
    @Published private(set) var frameLatencyMs: Int?

    /// The backend wants about one frame per second (see Plan.md).
    static let interval: Duration = .seconds(1)
    /// Pause after each detect reply before the next call, same as the web client's DETECT_MS.
    static let detectPause: Duration = .milliseconds(100)
    /// Edge of the square JPEG sent to YOLO, same as the web client.
    static let detectSide: CGFloat = 320
    /// Edge and quality of the square JPEG sent to /api/frame, same as the web client (FRAME_PX, JPEG_QUALITY).
    static let frameSide: CGFloat = 640
    static let frameQuality: CGFloat = 0.7

    let mixer = MediaMixer()
    private let picker = SharpFramePicker()
    private let photoTaker = PhotoTaker()
    private var detectTask: Task<Void, Never>?
    private var isCapturing = false
    /// One /api/frame call at a time; an object that stabilizes meanwhile waits for the next hold.
    private var isPricing = false
    private let speaker = Speaker()
    private var stabilizer = Stabilizer()

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            cameraAvailable = false
            status = "Camera access denied. Enable it in Settings."
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            cameraAvailable = false
            status = "No camera on this device (the Simulator has none)."
            return
        }
        do {
            await mixer.setSessionPreset(.hd1920x1080)
            try await mixer.attachVideo(device, track: 0) { unit in
                guard let device = unit.device else { return }
                try Self.tuneForWalking(device)
            }
            let photoTaker = photoTaker
            try await mixer.configuration { session in
                guard session.canAddOutput(photoTaker.output) else { return }
                session.addOutput(photoTaker.output)
            }
            photoTaker.configure(for: device)
            await mixer.addOutput(picker)
            await mixer.startRunning()
            UIApplication.shared.isIdleTimerDisabled = true
            status = "Ready"
        } catch {
            cameraAvailable = false
            status = "Camera failed: \(error.localizedDescription)"
        }
    }

    func setLive(_ on: Bool) {
        isLive = on
        detectTask?.cancel()
        stabilizer.reset()
        scan = Stabilizer.Scan(phase: .searching, target: nil, progress: 0)
        detectTimes = []
        detectRate = nil
        picker.setScoringEnabled(!on)
        guard on else {
            detections = []
            status = "Live capture off"
            return
        }
        // Gallery saving (and the sharpness scoring behind it) is paused while live, so the phone
        // spends its time on detection and pricing. `captureOnce` still works on its own.
        status = "Live: detecting and pricing"
        detectTask = Task { [weak self] in await self?.detectLoop() }
    }

    /// Sends the newest frame's center square to YOLO, pausing `detectPause` after each reply like the web client.
    private func detectLoop() async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            guard let client = BackendClient() else {
                backendError = "Set the backend URL"
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if let frame = picker.latestFrame() {
                let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
                do {
                    let jpeg = await Task.detached(priority: .userInitiated) {
                        CaptureStore.squareJPEG(pixelBuffer: frame, side: Self.detectSide)
                    }.value
                    guard let jpeg else { throw CocoaError(.fileWriteUnknown) }
                    let boxes = try await client.detect(jpeg: jpeg)
                    guard !Task.isCancelled else { return }
                    detections = boxes
                    detectFrameSize = size
                    track(boxes, frame: frame)
                    let now = ContinuousClock.now
                    detectLatencyMs = Int((now - started) / .milliseconds(1))
                    detectTimes.append(now)
                    detectTimes.removeAll { now - $0 > .seconds(2) }
                    detectRate = Double(detectTimes.count) / 2
                    backendError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    detections = []
                    backendError = "Backend unreachable: \(client.baseURL.host() ?? "?")"
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            }
            try? await Task.sleep(for: Self.detectPause)
        }
    }

    func refreshCount() {
        savedCount = CaptureStore.count()
    }

    func captureOnce() async {
        guard cameraAvailable, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        do {
            let saved: CaptureStore.Saved
            switch source {
            case .sharpestFrame:
                guard let pick = picker.takeBest() else {
                    status = "Waiting for first frame…"
                    return
                }
                // Encode off the main thread so the UI stays smooth.
                saved = try await Task.detached(priority: .userInitiated) {
                    try CaptureStore.save(pixelBuffer: pick.pixelBuffer, tag: "s\(Int(pick.score))")
                }.value
                lastScore = pick.score
            case .photo:
                let data = try await photoTaker.capture()
                saved = try CaptureStore.save(jpeg: data, tag: "photo")
                lastScore = nil
            }
            lastSize = saved.pixelSize
            savedCount += 1
            status = "Saved \(saved.url.lastPathComponent)"
        } catch {
            status = "Capture failed: \(error.localizedDescription)"
        }
    }

    /// Feeds each YOLO result to the stabilizer; once one object has been held for 2 s, prices it.
    private func track(_ boxes: [Detection], frame: CVPixelBuffer) {
        let wasSent = scan.phase == .sent
        scan = stabilizer.update(boxes, now: ProcessInfo.processInfo.systemUptime)
        if wasSent, scan.phase != .sent {
            lastReply = nil // a new object (or none): drop the old result
        }
        if scan.phase == .stabilized, !isPricing, let target = scan.target {
            stabilizer.markSent()
            scan.phase = .sent
            // Mark busy now, not inside the task, so the next detection can't start a second call.
            isPricing = true
            Task { await price(target, frame: frame) }
        }
    }

    /// Sends the frame's center square and the target's box through the pipeline, and speaks the answer.
    /// The box is normalized to the center square, the same square /api/detect saw.
    private func price(_ target: Detection, frame: CVPixelBuffer) async {
        defer { isPricing = false }
        guard let client = BackendClient() else { return }
        let jpeg = await Task.detached(priority: .userInitiated) {
            CaptureStore.squareJPEG(pixelBuffer: frame, side: Self.frameSide, quality: Self.frameQuality)
        }.value
        guard let jpeg else { return }
        lastReply = "Pricing \(target.label)…"
        let started = ContinuousClock.now
        do {
            let reply = try await client.frame(jpeg: jpeg, target: target)
            frameLatencyMs = Int((ContinuousClock.now - started) / .milliseconds(1))
            if reply.speak.isEmpty {
                let o = reply.objects.first
                lastReply = "Quiet · " + (o.map { $0.summary + ($0.reason.map { " (\($0))" } ?? "") } ?? "nothing to price")
            } else {
                lastReply = "“\(reply.speak)”"
                // Capture may have been stopped while the reply was on its way.
                if isLive { speaker.say(reply.speak) }
            }
        } catch {
            lastReply = "Pricing failed: \(error.localizedDescription)"
        }
    }

    /// Settings that cut motion blur on a chest-mounted phone without extra processing.
    nonisolated private static func tuneForWalking(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // Items are in the middle of the frame; focus there, and refocus fast rather than smoothly.
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = false
        }
        // Cap shutter time at 1/60s so walking doesn't smear frames; low light gets noisier instead.
        let cap = CMTime(value: 1, timescale: 60)
        if device.isExposureModeSupported(.continuousAutoExposure),
           cap >= device.activeFormat.minExposureDuration {
            device.exposureMode = .continuousAutoExposure
            device.activeMaxExposureDuration = cap
        }
    }
}

extension CameraModel: MTHKViewRepresentable.PreviewSource {
    nonisolated func connect(to view: MTHKView) {
        Task { await mixer.addOutput(view) }
    }
}
