import Foundation

/// Picks one object to scan and waits until it has stayed in view for half a second.
///
/// Started as a port of `web/stabilize.js` (same target choice: ignore people, nearest the
/// middle, bigger wins), but tuned for a chest-mounted phone, which sways far more than a
/// laptop webcam. Differences from the web version:
/// - Holds 0.5 s instead of 2 s.
/// - Follows the object frame to frame (overlap with its last box, or same label nearby)
///   instead of comparing against where it was first seen, so drift doesn't restart the count.
/// - Tolerates 1 s of missed detections instead of 0.5 s (blur, the item turning).
struct Stabilizer {
    static let holdS: TimeInterval = 0.5     // object must stay in view this long before the frame is sent (web: 2 s)
    static let minIoU = 0.3                  // overlap with its last box that still counts as the same object
    static let maxGapS: TimeInterval = 1.0   // YOLO can miss a few frames (blur, turning); longer means it left (web: 0.5 s)
    static let switchMargin = 0.15           // another object must score this much better to take over (web: 0.1)
    static let followDist = 0.35             // same label within this distance of its last box: same object, it moved
    static let centerWeight = 0.6            // "ideally in the middle"
    static let sizeWeight = 0.4              // "closer wins": closer objects are bigger in the frame
    static let ignore: Set<String> = ["person"] // the hand and body holding the item

    enum Phase: Equatable {
        case searching, stabilizing, stabilized, sent
    }

    struct Scan {
        var phase: Phase
        var target: Detection?
        var progress: Double
    }

    private struct Track {
        var target: Detection
        var since: TimeInterval
        var lastSeen: TimeInterval
        var sent: Bool
    }

    private var track: Track?

    /// Feeds one YOLO result. Boxes are [x1, y1, x2, y2], normalized 0–1 to the sent square.
    mutating func update(_ dets: [Detection], now: TimeInterval) -> Scan {
        let ranked = Self.candidates(dets)
        let best = ranked.first
        // Follow the tracked object: overlaps its last box, or the same label close by (it drifted).
        // Prefer the same label, so an overlapping neighbor doesn't take over the count.
        let same = track.flatMap { t in
            ranked.first { $0.label == t.target.label && Self.iou(t.target.box, $0.box) >= Self.minIoU }
                ?? ranked.first { Self.iou(t.target.box, $0.box) >= Self.minIoU }
                ?? ranked.first { $0.label == t.target.label && Self.centerDist($0.box, t.target.box) < Self.followDist }
        }
        func start(_ d: Detection) {
            track = Track(target: d, since: now, lastSeen: now, sent: false)
        }

        if let same, !(best.map { $0.id != same.id && Self.score($0.box) - Self.score(same.box) > Self.switchMargin } ?? false) {
            track?.target = same // keep the newest box and label (YOLO labels flicker); the count keeps going
            track?.lastSeen = now
        } else if let t = track, same == nil, now - t.lastSeen <= Self.maxGapS {
            // brief miss: keep counting on the last box we saw
        } else if let best {
            start(best)
        } else {
            track = nil
        }

        guard let t = track else { return Scan(phase: .searching, target: nil, progress: 0) }
        let progress = min(1, (now - t.since) / Self.holdS)
        let seen = t.lastSeen == now // never send on a frame where the object wasn't detected
        let phase: Phase = t.sent ? .sent : (progress >= 1 && seen ? .stabilized : .stabilizing)
        return Scan(phase: phase, target: t.target, progress: progress)
    }

    mutating func markSent() {
        track?.sent = true
    }

    mutating func reset() {
        track = nil
    }

    static func score(_ b: [Double]) -> Double {
        guard b.count == 4 else { return 0 }
        let dist = hypot((b[0] + b[2]) / 2 - 0.5, (b[1] + b[3]) / 2 - 0.5) / 0.5.squareRoot()
        let size = (max(0, b[2] - b[0]) * max(0, b[3] - b[1])).squareRoot()
        return centerWeight * (1 - min(1, dist)) + sizeWeight * size
    }

    static func candidates(_ dets: [Detection]) -> [Detection] {
        dets.filter { !ignore.contains($0.label) }.sorted { score($0.box) > score($1.box) }
    }

    static func iou(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 4, b.count == 4 else { return 0 }
        let w = min(a[2], b[2]) - max(a[0], b[0])
        let h = min(a[3], b[3]) - max(a[1], b[1])
        guard w > 0, h > 0 else { return 0 }
        let inter = w * h
        let area = { (r: [Double]) in (r[2] - r[0]) * (r[3] - r[1]) }
        return inter / (area(a) + area(b) - inter)
    }

    private static func centerDist(_ a: [Double], _ b: [Double]) -> Double {
        hypot((a[0] + a[2]) / 2 - (b[0] + b[2]) / 2, (a[1] + a[3]) / 2 - (b[1] + b[3]) / 2)
    }
}
