import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads `mpris:artUrl` to a local file so `Image(path:)` can decode it.
///
/// Same shape as Spotify's cover cache — path identity is a hash of the URL,
/// in-flight requests are not doubled, failures sit out a cooldown — but
/// stored under Lava's cache, not LavaSpotify's. `file://` is already a path
/// and is returned as-is.
enum ArtCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight: Set<String> = []
    nonisolated(unsafe) private static var failedUntil: [String: Date] = [:]
    nonisolated(unsafe) private static var root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Lava/mpris-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Local path if the picture is already on disk; otherwise starts a
    /// download and returns nil. `onReady` runs on a worker after a write.
    static func pathIfReady(for urlString: String, onReady: (@Sendable () -> Void)? = nil) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let file = fileURLPath(trimmed) { return file }
        guard let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }

        let path = cacheURL(for: trimmed).path
        if FileManager.default.fileExists(atPath: path) { return path }

        lock.lock()
        defer { lock.unlock() }
        if let until = failedUntil[trimmed], until > Date() { return nil }
        guard !inFlight.contains(trimmed) else { return nil }
        inFlight.insert(trimmed)
        Thread.detachNewThread {
            download(url: url, dest: cacheURL(for: trimmed), key: trimmed, onReady: onReady)
        }
        return nil
    }

    private static func fileURLPath(_ string: String) -> String? {
        guard let url = URL(string: string), url.scheme == "file" else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    private static func cacheURL(for urlString: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(format: "%016llx", hash)
        lock.lock()
        let dir = root
        lock.unlock()
        return dir.appendingPathComponent(hex + ".img")
    }

    private static func download(
        url: URL, dest: URL, key: String, onReady: (@Sendable () -> Void)?
    ) {
        defer {
            lock.lock()
            inFlight.remove(key)
            lock.unlock()
        }
        let box = DownloadBox()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 20)

        guard box.error == nil, box.status == 200, let data = box.data, !data.isEmpty else {
            lock.lock()
            failedUntil[key] = Date().addingTimeInterval(30)
            lock.unlock()
            return
        }
        let tmp = dest.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            onReady?()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            lock.lock()
            failedUntil[key] = Date().addingTimeInterval(30)
            lock.unlock()
        }
    }

    private final class DownloadBox: @unchecked Sendable {
        var data: Data?
        var status = 0
        var error: Error?
    }
}
