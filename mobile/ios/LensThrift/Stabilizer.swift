import Foundation

/// Picks one object to scan and waits until it has been held steady for about 2 seconds.
///
/// A Swift port of `web/stabilize.js`, so the phone and the web page send the backend the
/// same thing. Keep the constants and rules in sync with that file.
struct Stabilizer {
    static let holdS: TimeInterval = 2       // object must stay put this long before the frame is sent
    static let minIoU = 0.5                  // overlap with where the object was first seen; less means it moved
    static let maxGapS: TimeInterval = 0.5   // YOLO can miss a frame or two; longer than this means it left
    static let switchMargin = 0.1            // another object must score this much better to take over
    static let movedDist = 0.35              // same label this close to where it was: the object moved, not a new one
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
        var anchor: [Double]
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
        let same = track.flatMap { t in ranked.first { Self.iou(t.anchor, $0.box) >= Self.minIoU } }
        let moved = track.flatMap { t in
            same == nil ? ranked.first { $0.label == t.target.label && Self.centerDist($0.box, t.target.box) < Self.movedDist } : nil
        }
        func start(_ d: Detection) {
            track = Track(anchor: d.box, target: d, since: now, lastSeen: now, sent: false)
        }

        if let same, !(best.map { $0.id != same.id && Self.score($0.box) - Self.score(same.box) > Self.switchMargin } ?? false) {
            track?.target = same // keep the newest box and label (YOLO labels flicker)
            track?.lastSeen = now
        } else if let moved {
            start(moved)
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
