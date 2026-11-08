import Foundation

struct APIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Talks to the engine over HTTP on 127.0.0.1, authenticated with a per-launch token.
final class API: @unchecked Sendable {
    let base: URL
    let token: String
    private let session: URLSession

    init(port: Int, token: String) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.connectionProxyDictionary = [:]
        session = URLSession(configuration: cfg)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    func call<T: Decodable>(_ path: String, _ body: [String: Any]? = nil, as: T.Type = T.self) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue(token, forHTTPHeaderField: "X-Dwn-Token")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError(message: "The download engine didn't respond. Try again.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(message: msg ?? "The download engine couldn't do that (error \(code)).")
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(message: "The download engine sent a reply Dwn couldn't read. Try updating the engine in Settings.")
        }
    }

    func savePrefs(_ p: Prefs) async throws -> Prefs {
        let data = try Self.encoder.encode(p)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try await call("prefs", dict)
    }
}
