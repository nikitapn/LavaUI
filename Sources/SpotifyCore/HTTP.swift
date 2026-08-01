import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared synchronous HTTP helper for Linux Foundation (no async URLSession.bytes).
enum HTTP {
    /// Holds callback results so the `@Sendable` data-task closure can write
    /// them without capturing mutable locals (Swift 6).
    final class Box: @unchecked Sendable {
        var data: Data?
        var status = 0
        var error: Error?
    }

    static func data(for request: URLRequest, timeout: TimeInterval = 30) throws -> (Data, Int) {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
            return (Data(), 204)
        }
        guard let data = box.data else {
            throw SpotifyError("Empty response from \(request.url?.absoluteString ?? "?")")
        }
        return (data, box.status)
    }

    static func data(from url: URL, timeout: TimeInterval = 30) throws -> (Data, Int) {
        try data(for: URLRequest(url: url), timeout: timeout)
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}
