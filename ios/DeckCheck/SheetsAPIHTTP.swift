import Foundation
import DeckCheckCore

// The device shell for the v2 Sheets/OAuth layer: a thin URLSession
// executor for the pure `HTTPRequestSpec`s built in DeckCheckCore (GoogleOAuth /
// GoogleSheets). All the request/response *logic* is tested in the core; this just
// fires the bytes and surfaces HTTP errors with the server's body for debugging.

enum SheetsHTTPError: LocalizedError {
    case notHTTP
    case status(code: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notHTTP: return "No HTTP response."
        case let .status(code, body):
            let snippet = body.prefix(400)
            return "HTTP \(code): \(snippet)"
        }
    }
}

struct SheetsAPIHTTP {
    var session: URLSession = .shared

    /// Execute a request spec and return the response body, throwing on non-2xx.
    func execute(_ spec: HTTPRequestSpec) async throws -> Data {
        var req = URLRequest(url: spec.url)
        req.httpMethod = spec.method.rawValue
        for (key, value) in spec.headers { req.setValue(value, forHTTPHeaderField: key) }
        req.httpBody = spec.body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SheetsHTTPError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw SheetsHTTPError.status(code: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
