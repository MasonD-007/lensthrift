import HaishinKit
import SwiftUI

struct CaptureView: View {
    @StateObject private var camera = CameraModel()
    @State private var showGallery = false
    @State private var showBackend = false
    @State private var backendURL = BackendClient.savedURL

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.cameraAvailable {
                MTHKViewRepresentable(previewSource: camera, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea()
                if camera.isLive, let frameSize = camera.detectFrameSize {
                    BoxOverlay(detections: camera.detections, frameSize: frameSize)
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
        .alert("Backend URL", isPresented: $showBackend) {
            TextField("http://192.168.1.10:8080", text: $backendURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Save") { BackendClient.savedURL = backendURL }
            Button("Cancel", role: .cancel) { backendURL = BackendClient.savedURL }
        } message: {
            Text("Where `make run` is serving, or its tunnel URL.")
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
                        Label(String("YOLO \(camera.detections.count) boxes · \(ms) ms"), systemImage: "viewfinder")
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
                backendURL = BackendClient.savedURL
                showBackend = true
            } label: {
                Image(systemName: "server.rack")
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
            .accessibilityLabel("Backend URL")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .tint(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
