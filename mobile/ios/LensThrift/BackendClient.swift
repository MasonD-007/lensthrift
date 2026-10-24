import Foundation

/// One YOLO box from `POST /api/detect`, normalized 0–1 to the image that was sent.
struct Detection: Decodable, Identifiable, Sendable {
    let label: String
    let conf: Double
    /// x1, y1, x2, y2
    let box: [Double]

    let id = UUID()

    private enum CodingKeys: String, CodingKey {
        case label, conf, box
    }
}

/// Talks to the FastAPI backend in `backend/app/main.py`.
struct BackendClient: Sendable {
    static let urlKey = "backendURL"

    private static let buildDefaultKey = "backendURLBuildDefault"

    /// Saved in the app, else the build's `LTBackendURL` (set with `BACKEND_URL=` at build time).
    /// A build with a different default clears the saved URL, so reinstalling points at the new backend.
    static var savedURL: String {
        get {
            let defaults = UserDefaults.standard
            let buildDefault = Bundle.main.object(forInfoDictionaryKey: "LTBackendURL") as? String ?? ""
            if defaults.string(forKey: buildDefaultKey) != buildDefault {
                defaults.set(buildDefault, forKey: buildDefaultKey)
                defaults.removeObject(forKey: urlKey)
            }
            return defaults.string(forKey: urlKey) ?? buildDefault
        }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    let baseURL: URL

    init?(_ string: String = BackendClient.savedURL) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return nil }
        baseURL = url
    }

    func detect(jpeg: Data) async throws -> [Detection] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/detect"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.upload(for: request, from: jpeg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([Detection].self, from: data)
    }

    /// The pipeline's answer for one frame: the line to say (empty means stay quiet).
    struct FrameReply: Decodable, Sendable {
        let speak: String
        /// Per-object results. Older backends sent only a count; that decodes as no details.
        let objects: [FrameObject]
        let objectCount: Int

        private enum CodingKeys: String, CodingKey {
            case speak, objects
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            speak = try c.decodeIfPresent(String.self, forKey: .speak) ?? ""
            if let list = try? c.decode([FrameObject].self, forKey: .objects) {
                objects = list
                objectCount = list.count
            } else {
                objects = []
                objectCount = (try? c.decode(Int.self, forKey: .objects)) ?? 0
            }
        }
    }

    /// One row of `/api/frame`'s `objects` (see `log_row` in backend/app/main.py).
    struct FrameObject: Decodable, Sendable {
        let label: String?
        let item: String?
        let low: Double?
        let high: Double?
        let decision: String?

        /// "umbrella $3–8", or the YOLO label when nothing was priced.
        var summary: String {
            let name = item ?? label ?? "object"
            guard let low, let high else { return name }
            return "\(name) $\(Int(low))–\(Int(high))"
        }
    }

    /// Runs the full pipeline (YOLO → Jev → Gemini → decide) on one frame.
    func frame(jpeg: Data) async throws -> FrameReply {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/frame"))
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        // Grounded pricing can take several seconds on a new item.
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.upload(for: request, from: jpeg)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            // FastAPI errors carry {"detail": "..."}; e.g. 503 when backend/.env is missing keys.
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw FrameError(status: http.statusCode, detail: detail)
        }
        return try JSONDecoder().decode(FrameReply.self, from: data)
    }

    struct FrameError: LocalizedError {
        let status: Int
        let detail: String?
        var errorDescription: String? { "\(status) \(detail ?? "")" }
    }
}
