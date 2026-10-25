import CoreImage
import Foundation

/// Brandon's backend pipeline (backend/app/pipeline.py) running on the phone: crop → Jev → Gemini
/// (with Google Search) → comps → decide → whisper. No Mac or hotspot; the phone calls Jev and
/// Gemini itself with keys from the Keychain.
///
/// Constants, prompts and rules mirror backend/app/{config,crops,jev,gemini,comps,decide,memory}.py.
/// Keep them in sync when the backend changes.
actor OnDevicePipeline {
    // backend/app/config.py
    static let jevThreshold = 0.5
    static let geminiMinConfidence = 0.6
    static let cooldownS: TimeInterval = 30
    static let defaultTag = 10.0
    static let defaultModel = "gemini-3.8-flash"
    /// web/capture.js FRAME_PX: the square the backend crops from.
    static let frameSide: CGFloat = 640

    struct Quote: Sendable {
        let name: String
        let description: String
        var low: Double
        var high: Double
        let confidence: Double
    }

    struct Result: Sendable {
        let speak: String
        let object: BackendClient.FrameObject?
        /// Milliseconds per stage, for the status bar.
        var timings: String = ""
    }

    enum Failure: LocalizedError {
        case missingKeys, jev(String), gemini(String)
        var errorDescription: String? {
            switch self {
            case .missingKeys: "Add your Gemini and TypeSafe keys in settings"
            case .jev(let m): "jev error: \(m)"
            case .gemini(let m): "gemini error: \(m)"
            }
        }
    }

    private let comps: [String: [String: Any]]
    private var quotes: [String: Quote] = [:]          // memory.py _quotes
    private var spoken: [String: Date] = [:]           // memory.py _spoken
    private var looks: [String: [(look: [UInt8], name: String)]] = [:] // memory.py _looks
    private let ciContext = CIContext()

    init(compsURL: URL? = Bundle.main.url(forResource: "comps", withExtension: "json")) {
        // The same comps.json the backend reads, bundled into the app at build time.
        if let url = compsURL,
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            comps = json
        } else {
            comps = [:]
        }
    }

    /// Prices the one stabilized object. `box` is normalized to the frame's center square.
    func process(frame: CVPixelBuffer, target: Detection) async throws -> Result {
        guard let keys = Keys.load() else { throw Failure.missingKeys }
        guard let (crop, look) = makeCrop(frame, box: target.box) else { return Result(speak: "", object: nil) }

        let started = Date()
        func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

        // Start Gemini alongside Jev instead of after it (the backend runs them one after the other).
        // A repeat item skips Gemini via the look cache, like the backend.
        let cached = nameForLook(target.label, look).flatMap { quotes[Self.normalize($0)] }
        let geminiStarted = Date()
        let geminiTask: Task<(Quote, Int), Error>? = cached == nil ? Task {
            let q = try await self.gemini(crop, apiKey: keys.gemini, model: keys.model)
            return (q, ms(geminiStarted))
        } : nil

        let score: Double
        do {
            score = try await jev(crop, apiKey: keys.typesafe)
        } catch {
            geminiTask?.cancel()
            throw error
        }
        let jevMs = ms(started)
        guard score >= Self.jevThreshold else {
            geminiTask?.cancel() // not worth pricing; stop waiting on Gemini
            return Result(speak: "", object: row(target, quote: nil, decision: "quiet", reason: "not resalable"),
                          timings: "Jev \(jevMs) ms")
        }

        var quote: Quote
        var geminiNote = "Gemini cached"
        if let cached {
            quote = cached
        } else {
            let (q, geminiMs) = try await geminiTask!.value
            quote = q
            geminiNote = "Gemini \(String(format: "%.1f", Double(geminiMs) / 1000)) s"
            applyComps(&quote)
            quotes[Self.normalize(quote.name)] = quote
            rememberLook(target.label, look, name: quote.name)
        }
        let timings = "Jev \(jevMs) ms · \(geminiNote)"

        let tag = tagFor(quote.name)
        var (speak, reason) = Self.decide(tag: tag, quote: quote)
        if speak, let at = spoken[Self.normalize(quote.name)], Date().timeIntervalSince(at) < Self.cooldownS {
            speak = false
            reason = "spoken recently"
        }
        if speak { spoken[Self.normalize(quote.name)] = Date() }
        return Result(speak: speak ? Self.phrase(quote) : "",
                      object: row(target, quote: quote, decision: speak ? "spoke" : "quiet", reason: reason),
                      timings: timings)
    }

    func clearMemory() {
        quotes.removeAll()
        spoken.removeAll()
        looks.removeAll()
    }

    // MARK: decide.py

    static func decide(tag: Double, quote: Quote) -> (Bool, String) {
        if quote.confidence < geminiMinConfidence { return (false, "low confidence") }
        if quote.low <= tag { return (false, "resale does not beat tag") }
        return (true, "resale beats tag")
    }

    static func phrase(_ q: Quote) -> String {
        "\(Int(q.low.rounded())) to \(Int(q.high.rounded())) dollars, \(q.description)."
    }

    // MARK: comps.py

    private func match(_ name: String) -> [String: Any]? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        for (key, entry) in comps {
            let k = key.lowercased().trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !n.isEmpty, k.contains(n) || n.contains(k) { return entry }
        }
        return nil
    }

    private func applyComps(_ q: inout Quote) {
        guard let e = match(q.name), let low = e["low"] as? Double, let high = e["high"] as? Double else { return }
        q.low = low
        q.high = high
    }

    private func tagFor(_ name: String) -> Double {
        (match(name)?["tag"] as? Double) ?? Self.defaultTag
    }

    // MARK: memory.py

    static func normalize(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func rememberLook(_ label: String, _ look: [UInt8], name: String) {
        var list = looks[label, default: []]
        list.append((look, Self.normalize(name)))
        if list.count > 50 { list.removeFirst(list.count - 50) }
        looks[label] = list
    }

    private func nameForLook(_ label: String, _ look: [UInt8]) -> String? {
        func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
        }
        guard let best = looks[label]?.min(by: { distance($0.look, look) < distance($1.look, look) }),
              distance(best.look, look) <= 12 else { return nil }
        return best.name
    }

    // MARK: crops.py

    /// Crop JPEG for Jev/Gemini (10% margin, 280–1568px, quality 0.9) and the 8x8 "look" thumbnail.
    private func makeCrop(_ frame: CVPixelBuffer, box: [Double]) -> (Data, [UInt8])? {
        guard box.count == 4 else { return nil }
        // Same image the web client sends the backend: the center square at 640px. Cropping from the
        // full 1080px frame made crops up to ~3x bigger, which slowed both Jev and Gemini.
        let full = CIImage(cvPixelBuffer: frame)
        let e = full.extent
        let side = min(e.width, e.height)
        let s = Self.frameSide
        let image = full
            .cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - side / 2), y: -(e.midY - side / 2)))
            .transformed(by: CGAffineTransform(scaleX: s / side, y: s / side))
        // Box is normalized to this square; CIImage's origin is bottom-left.
        let sq = CGRect(x: 0, y: 0, width: s, height: s)
        func rect(margin: Double) -> CGRect {
            let x0 = box[0] * s, y0 = box[1] * s, x1 = box[2] * s, y1 = box[3] * s
            let mx = (x1 - x0) * margin, my = (y1 - y0) * margin
            let left = max(0, x0 - mx), top = max(0, y0 - my)
            let right = min(s, x1 + mx), bottom = min(s, y1 + my)
            return CGRect(x: sq.minX + left, y: sq.maxY - bottom, width: max(1, right - left), height: max(1, bottom - top))
        }
        let r = rect(margin: 0.10).integral
        var crop = image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        var scale = 1.0
        if min(r.width, r.height) < 280 { scale = 280 / min(r.width, r.height) }
        if max(r.width, r.height) * scale > 1568 { scale = 1568 / max(r.width, r.height) }
        if scale != 1 { crop = crop.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let jpeg = ciContext.jpegRepresentation(
            of: crop, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        ) else { return nil }

        let lr = rect(margin: 0)
        let tiny = image.cropped(to: lr)
            .transformed(by: CGAffineTransform(translationX: -lr.minX, y: -lr.minY))
            .transformed(by: CGAffineTransform(scaleX: 8 / lr.width, y: 8 / lr.height))
        var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
        ciContext.render(tiny, toBitmap: &rgba, rowBytes: 8 * 4, bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let look = rgba.enumerated().filter { $0.offset % 4 != 3 }.map(\.element) // drop alpha: RGB like PIL
        return (jpeg, look)
    }

    private func row(_ d: Detection, quote: Quote?, decision: String, reason: String) -> BackendClient.FrameObject {
        BackendClient.FrameObject(label: d.label, item: quote?.name, low: quote?.low, high: quote?.high,
                                  decision: decision, reason: reason)
    }

    // MARK: jev.py

    private func jev(_ jpeg: Data, apiKey: String) async throws -> Double {
        let ref = "\(UUID().uuidString.lowercased())-item"
        let body: [String: Any] = [
            "model": "jev-latest",
            "state": ["item": ref],
            "assets": [ref: ["type": "image", "part": "item-photo"]],
            "questions": ["resalable": [
                "type": "noul",
                "instructions": "Is `item` a physical object someone could resell secondhand, not a person, a wall, a shelf or another fixture?",
            ]],
        ]
        let boundary = "lensthrift-\(UUID().uuidString)"
        var form = Data()
        func part(_ header: String, _ data: Data) {
            form.append("--\(boundary)\r\n\(header)\r\n\r\n".data(using: .utf8)!)
            form.append(data)
            form.append("\r\n".data(using: .utf8)!)
        }
        part("Content-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json",
             try JSONSerialization.data(withJSONObject: body))
        part("Content-Disposition: form-data; name=\"item-photo\"; filename=\"item.jpg\"\r\nContent-Type: image/jpeg", jpeg)
        form.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: form)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.jev("\((resp as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: Any],
              let resalable = answers["resalable"] as? [String: Any],
              let noul = (resalable["noul"] as? NSNumber)?.doubleValue else {
            throw Failure.jev("answer missing: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return noul
    }

    // MARK: gemini.py

    static let pricePrompt = "You price items for a thrift-store reseller. Identify the item in the photo. "
        + "Search for recent used or sold prices (sold listings on eBay, Etsy, Poshmark and similar), "
        + "not retail, new or asking prices, and give a realistic secondhand resale range in USD. "
        + "Return only JSON with these fields: name (a few words with one distinguishing detail such as maker, material, pattern or era), "
        + "description (a short phrase that is spoken aloud right after the price), low (number, USD), high (number, USD), "
        + "confidence (0 to 1: how sure you are of both the identification and the price)."

    private func gemini(_ jpeg: Data, apiKey: String, model: String) async throws -> Quote {
        let body: [String: Any] = [
            "contents": [["parts": [
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["text": Self.pricePrompt],
            ]]],
            "tools": [["google_search": [String: Any]()]],
            // Thinking off: measured 5–6 s per grounded price vs 38–90 s with the default thinking.
            "generationConfig": ["temperature": 0.2, "thinkingConfig": ["thinkingBudget": 0]],
        ]
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        // With thinking off a grounded price takes ~5–6 s; leave headroom for slow networks.
        req.timeoutInterval = 25
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: try JSONSerialization.data(withJSONObject: body))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.gemini("\((resp as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parts = ((json?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = parts?.compactMap { $0["text"] as? String }.joined() ?? ""
        return try Self.parseQuote(text)
    }

    /// gemini.py `_parse`: the whole text, a ```json fence, or the outermost {...}.
    static func parseQuote(_ text: String) throws -> Quote {
        var candidates = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let fence = text.range(of: "```(?:json)?\\s*(\\{[\\s\\S]*?\\})\\s*```", options: .regularExpression) {
            candidates.append(String(text[fence]).replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: ""))
        }
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
            candidates.append(String(text[a...b]))
        }
        for c in candidates {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(c.utf8)) as? [String: Any],
                  let name = obj["name"] as? String, !name.isEmpty,
                  let low = (obj["low"] as? NSNumber)?.doubleValue,
                  let high = (obj["high"] as? NSNumber)?.doubleValue,
                  let conf = (obj["confidence"] as? NSNumber)?.doubleValue, (0...1).contains(conf) else { continue }
            return Quote(name: name, description: obj["description"] as? String ?? "",
                         low: min(low, high), high: max(low, high), confidence: conf)
        }
        throw Failure.gemini("unparseable Gemini output: \(text.prefix(200))")
    }
}
