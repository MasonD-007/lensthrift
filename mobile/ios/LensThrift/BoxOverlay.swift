import SwiftUI

/// Draws YOLO boxes on top of the aspect-filled camera preview.
///
/// Boxes come back normalized to the centered square of the frame (that's what we
/// send), so each point maps square → frame → aspect-filled view.
struct BoxOverlay: View {
    let detections: [Detection]
    /// Pixel size of the frame the boxes belong to (1080x1920 in portrait).
    let frameSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let map = Mapping(view: geo.size, frame: frameSize)
            ZStack(alignment: .topLeading) {
                // What YOLO sees: the center square.
                Rectangle()
                    .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                    .frame(width: map.squareRect.width, height: map.squareRect.height)
                    .offset(x: map.squareRect.minX, y: map.squareRect.minY)

                ForEach(detections) { detection in
                    let rect = map.rect(for: detection.box)
                    Rectangle()
                        .stroke(.yellow, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    Text(verbatim: "\(detection.label) \(Int(detection.conf * 100))%")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.yellow)
                        .foregroundStyle(.black)
                        .offset(x: rect.minX, y: max(rect.minY - 16, 0))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private struct Mapping {
        let scale: CGFloat
        let origin: CGPoint
        let squareSide: CGFloat
        let squareOrigin: CGPoint

        init(view: CGSize, frame: CGSize) {
            // .resizeAspectFill: scale to cover the view, centered, overflow cropped.
            scale = max(view.width / frame.width, view.height / frame.height)
            origin = CGPoint(x: (view.width - frame.width * scale) / 2, y: (view.height - frame.height * scale) / 2)
            squareSide = min(frame.width, frame.height)
            squareOrigin = CGPoint(x: (frame.width - squareSide) / 2, y: (frame.height - squareSide) / 2)
        }

        var squareRect: CGRect {
            rect(for: [0, 0, 1, 1])
        }

        func rect(for box: [Double]) -> CGRect {
            guard box.count == 4 else { return .zero }
            func point(_ nx: Double, _ ny: Double) -> CGPoint {
                CGPoint(
                    x: origin.x + (squareOrigin.x + nx * squareSide) * scale,
                    y: origin.y + (squareOrigin.y + ny * squareSide) * scale
                )
            }
            let a = point(box[0], box[1])
            let b = point(box[2], box[3])
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
    }
}
