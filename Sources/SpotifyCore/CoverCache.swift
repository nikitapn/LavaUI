import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads remote cover art to a local directory and hands out file paths.
///
/// `ImageStore` only knows about files on disk. A real client is waiting on the
/// network first, then on decode — this is the network half. Workers download;
/// callers still use `ImageStore.imageIfLoaded` for the decode/upload half and
/// draw a placeholder while either stage is outstanding.
///
/// Paths are stable per URL (FNV-1a of the URL string), so a second request for
/// the same cover is free after the first land. Failures are sticky for a short
/// cooldown so a 404 does not spin the network on every body pass.
public enum CoverCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var inFlight: Set<String> = []
    nonisolated(unsafe) private static var failedUntil: [String: Date] = [:]
    nonisolated(unsafe) private static var root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("LavaSpotify/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Optional override for tests.
    public static func setRoot(_ url: URL) {
        lock.lock()
        root = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        lock.unlock()
    }

    /// Local path if the cover is already on disk; otherwise kicks off a
    /// download and returns nil. `onReady` runs on a background thread after a
    /// successful write — the caller should hop to `MainQueue` from there.
    public static func pathIfReady(for urlString: String, onReady: (@Sendable () -> Void)? = nil) -> String? {
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        let path = fileURL(for: urlString).path
        if FileManager.default.fileExists(atPath: path) {
            return path
        }

        lock.lock()
        defer { lock.unlock() }
        if let until = failedUntil[urlString], until > Date() {
            return nil
        }
        guard !inFlight.contains(urlString) else { return nil }
        inFlight.insert(urlString)

        Thread.detachNewThread {
            download(url: url, dest: fileURL(for: urlString), key: urlString, onReady: onReady)
        }
        return nil
    }

    /// Synchronous path for code that already sits on a worker.
    public static func ensureDownloaded(urlString: String) -> String? {
        if let ready = pathIfReady(for: urlString) { return ready }
        // Wait briefly for an in-flight download of the same URL.
        let dest = fileURL(for: urlString).path
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: dest) { return dest }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: dest) ? dest : nil
    }

    private static func fileURL(for urlString: String) -> URL {
        // FNV-1a 64-bit — enough to avoid collisions for a cover cache, no
        // CryptoKit dependency (not always present on Linux toolchains).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hex = String(format: "%016llx", hash)
        lock.lock()
        let dir = root
        lock.unlock()
        return dir.appendingPathComponent(hex + ".jpg")
    }

    private static func download(
        url: URL,
        dest: URL,
        key: String,
        onReady: (@Sendable () -> Void)?
    ) {
        defer {
            lock.lock()
            inFlight.remove(key)
            lock.unlock()
        }

        let data: Data
        do {
            let (body, status) = try HTTP.data(from: url)
            guard status == 200, !body.isEmpty else {
                lock.lock()
                failedUntil[key] = Date().addingTimeInterval(30)
                lock.unlock()
                return
            }
            data = body
        } catch {
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
}
