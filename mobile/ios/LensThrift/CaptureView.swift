import HaishinKit
import SwiftUI

struct CaptureView: View {
    @StateObject private var camera = CameraModel()
    @State private var showGallery = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.cameraAvailable {
                MTHKViewRepresentable(previewSource: camera, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea()
                if camera.isLive, let frameSize = camera.detectFrameSize {
                    BoxOverlay(detections: camera.detections, frameSize: frameSize, scan: camera.scan)
                        .ignoresSafeArea()
                }
            } else {
                Image(systemName: "video.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                statusBar
                Spacer()
                controls
            }
            .padding(16)
        }
        .task { await camera.start() }
        .sheet(isPresented: $showGallery) {
            GalleryView { camera.refreshCount() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView { camera.settingsChanged() }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.status)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 12) {
                Label("\(camera.savedCount)", systemImage: "photo.stack")
                if let size = camera.lastSize {
                    Label(String("\(Int(size.width))×\(Int(size.height))"), systemImage: "aspectratio")
                }
                if let score = camera.lastScore {
                    Label(String(Int(score)), systemImage: "camera.metering.center.weighted")
                }
                if camera.isLive {
                    Label("LIVE", systemImage: "record.circle")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption.monospacedDigit())
            if camera.isLive {
                Group {
                    if let error = camera.backendError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if let ms = camera.detectLatencyMs {
                        Label(String("YOLO \(camera.detections.count) boxes · \(ms) ms") + (camera.detectRate.map { String(format: " · %.1f/s", $0) } ?? ""), systemImage: "viewfinder")
                    }
                    if let phase = phaseText {
                        Label(phase, systemImage: "scope")
                    }
                    if let timings = camera.stageTimings {
                        Label(timings, systemImage: "stopwatch")
                    }
                    if let reply = camera.lastReply {
                        Label(reply + (camera.frameLatencyMs.map { " · \($0) ms" } ?? ""), systemImage: "speaker.wave.2")
                            .lineLimit(2)
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// "Stabilizing bottle 1.2 / 2.0 s", matching the web page's wording.
    private var phaseText: String? {
        let scan = camera.scan
        guard let target = scan.target else { return camera.isLive ? "Searching…" : nil }
        switch scan.phase {
        case .stabilizing:
            return String(format: "Stabilizing %@… %.1f / %.1f s", target.label, scan.progress * Stabilizer.holdS, Stabilizer.holdS)
        case .stabilized, .sent:
            return "Stabilized: \(target.label)"
        case .searching:
            return nil
        }
    }

    private var controls: some View {
        HStack {
            Button {
                showGallery = true
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("Gallery")
            .frame(maxWidth: .infinity, alignment: .leading)

            // One button: start or stop capturing the clearest frame each second.
            Button {
                camera.setLive(!camera.isLive)
            } label: {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4)
                    if camera.isLive {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 28, height: 28)
                    } else {
                        Circle().fill(.red).padding(8)
                    }
                }
                .frame(width: 72, height: 72)
            }
            .accessibilityLabel(camera.isLive ? "Stop capture" : "Start capture")
            .disabled(!camera.cameraAvailable)

            Button {
                showSettings = true
            } label: {
                Image(systemName: camera.engine == .phone ? "iphone.gen3" : "server.rack")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(camera.backendError == nil && camera.detectLatencyMs != nil ? .green : .gray)
                            .frame(width: 10, height: 10)
                            .padding(6)
                    }
            }
            .accessibilityLabel("Settings")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .tint(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
