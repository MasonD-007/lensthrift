import HaishinKit
import SwiftUI

struct CaptureView: View {
    @StateObject private var camera = CameraModel()
    @State private var showGallery = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.cameraAvailable {
                MTHKViewRepresentable(previewSource: camera, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea()
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

            Text(camera.isLive ? "1 / sec" : "Start")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .tint(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
