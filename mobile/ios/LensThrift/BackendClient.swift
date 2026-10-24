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
}
