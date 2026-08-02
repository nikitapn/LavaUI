import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared synchronous HTTP helper for Linux Foundation (no async URLSession.bytes).
enum HTTP {
    struct Response: Sendable {
        var data: Data
        var status: Int
        var headers: [String: String]

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Holds callback results so the `@Sendable` data-task closure can write
    /// them without capturing mutable locals (Swift 6).
    final class Box: @unchecked Sendable {
        var data: Data?
        var status = 0
        var headers: [String: String] = [:]
        var error: Error?
    }

    static func data(for request: URLRequest, timeout: TimeInterval = 30) throws -> (Data, Int) {
        let response = try response(for: request, timeout: timeout)
        return (response.data, response.status)
    }

    static func response(for request: URLRequest, timeout: TimeInterval = 30) throws -> Response {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            if let response = response as? HTTPURLResponse {
                box.status = response.statusCode
                box.headers = response.allHeaderFields.reduce(into: [:]) { result, entry in
                    result[String(describing: entry.key)] = String(describing: entry.value)
                }
            }
            box.error = error
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout)

        if let error = box.error {
            throw SpotifyError(error.localizedDescription)
        }
        // Player endpoints return 204 No Content with an empty body.
        if box.status == 204 {
            return Response(data: Data(), status: 204, headers: box.headers)
        }
        guard let data = box.data else {
            throw SpotifyError("Empty response from \(request.url?.absoluteString ?? "?")")
        }
        return Response(data: data, status: box.status, headers: box.headers)
    }

    static func data(from url: URL, timeout: TimeInterval = 30) throws -> (Data, Int) {
        try data(for: URLRequest(url: url), timeout: timeout)
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}
