import ImageIO
import SwiftUI

/// One saved capture, with what's needed to check size and 1 fps spacing.
struct CaptureItem: Identifiable, Hashable {
    let url: URL
    let date: Date
    let pixelSize: CGSize
    /// Sharpness score from the file name (higher is clearer), nil for native photos.
    let sharpness: Int?
    /// Seconds since the previous capture, nil for the first one.
    var gap: TimeInterval?

    var id: URL { url }

    static func loadAll() -> [CaptureItem] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: CaptureStore.directory, includingPropertiesForKeys: nil)) ?? []
        var items = urls
            .filter { $0.pathExtension == "jpg" }
            .compactMap { url -> CaptureItem? in
                guard let date = CaptureStore.date(from: url) else { return nil }
                return CaptureItem(url: url, date: date, pixelSize: pixelSize(of: url), sharpness: sharpness(of: url), gap: nil)
            }
            .sorted { $0.date < $1.date }
        for i in items.indices.dropFirst() {
            items[i].gap = items[i].date.timeIntervalSince(items[i - 1].date)
        }
        return items.reversed()
    }

    /// Reads the `-s<score>` tag `CameraModel` puts in file names.
    private static func sharpness(of url: URL) -> Int? {
        let tag = url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? ""
        guard tag.hasPrefix("s") else { return nil }
        return Int(tag.dropFirst())
    }

    private static func pixelSize(of url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return .zero }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        // EXIF orientations 5–8 are rotated 90°, so width and height swap on display.
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

struct GalleryView: View {
    var onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [CaptureItem] = []
    @State private var confirmClear = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No captures yet", systemImage: "photo.on.rectangle", description: Text("Turn on Live capture or tap the shutter."))
                } else {
                    ScrollView {
                        summary
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(items) { item in
                                NavigationLink(value: item) {
                                    Thumbnail(item: item)
                                }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .navigationTitle("Captures (\(items.count))")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CaptureItem.self) { CaptureDetail(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .disabled(items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete all \(items.count) captures?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    for item in items { try? FileManager.default.removeItem(at: item.url) }
                    items = []
                    onChange()
                }
            }
        }
        .task { items = CaptureItem.loadAll() }
    }

    /// Average spacing across the run, to check the 1 photo per second target at a glance.
    private var summary: some View {
        let gaps = items.compactMap(\.gap).filter { $0 < 5 }
        let average = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        return HStack {
            if let average {
                Label(String(format: "Avg gap %.2fs", average), systemImage: "timer")
            }
            Spacer()
            if let first = items.first {
                Label(String("\(Int(first.pixelSize.width))×\(Int(first.pixelSize.height))"), systemImage: "aspectratio")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

private struct Thumbnail: View {
    let item: CaptureItem
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(9 / 16, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                HStack {
                    if let gap = item.gap, gap < 5 {
                        Text(String(format: "+%.2fs", gap))
                    }
                    Spacer(minLength: 0)
                    if let sharpness = item.sharpness {
                        Text(verbatim: "◎\(sharpness)")
                    }
                }
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 4)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
            }
            .task(id: item.url) { image = await Self.thumbnail(for: item.url) }
    }

    private static func thumbnail(for url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 300
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

private struct CaptureDetail: View {
    let item: CaptureItem

    var body: some View {
        VStack(spacing: 12) {
            if let image = UIImage(contentsOfFile: item.url.path) {
                Image(uiImage: image).resizable().scaledToFit()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                Text(verbatim: "\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height)) px")
                if let gap = item.gap {
                    Text(String(format: "%.3fs after previous", gap))
                }
                if let sharpness = item.sharpness {
                    Text(verbatim: "Sharpness \(sharpness)")
                }
            }
            .font(.footnote.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            Spacer(minLength: 0)
        }
        .toolbar {
            ShareLink(item: item.url)
        }
    }
}
