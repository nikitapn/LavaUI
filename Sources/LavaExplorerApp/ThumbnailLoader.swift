import Foundation
import LavaExplorerCore
import LavaUI

#if canImport(Glibc)
import Glibc
#endif

/// Thumbnails for the rows on screen, made on workers and kept in the shared
/// freedesktop cache (`ThumbnailCache`).
///
/// A row asks with `path(for:)` on every body. The first ask queues the file
/// and answers nil — the row draws its glyph — and the answer arrives through
/// `onChange` once a worker has it. What a worker does, cheapest first:
///
/// 1. a thumbnail already in the cache that is still good: answer it. Any
///    file manager on the machine may have made it;
/// 2. a failure already recorded for this version of the file: answer
///    nothing, without trying again;
/// 3. otherwise decode the picture at 128 pixels, write the thumbnail, and
///    answer that — or record the failure.
///
/// Decoding happens here, in the explorer's own process, not in the
/// compositor: a full photograph is a quarter of a second of `stbi_load`
/// whoever does it, and here it is paid once per picture *ever*, on a thread
/// that draws nothing. What the compositor is given is a 128-pixel PNG.
///
/// **Newest first.** The queue is a stack: scrolling queues the rows coming
/// into view on top of the ones that left, so what is on screen is what gets
/// done. Leaving a folder drops what was queued for it (`retain`).
///
/// **A thumbnail is shown through a name with its version in it** — a link in
/// `$XDG_RUNTIME_DIR/lava-thumbnails` named after the picture and its
/// modification time. The cache file itself keeps one name for the life of
/// the picture, and every image cache on the way to the screen keys on the
/// path it is given, so a photo edited while the folder is open would go on
/// showing its old thumbnail. A new version is a new name.
final class ThumbnailLoader: @unchecked Sendable {
    /// Called on the main queue when answers have arrived, once per batch.
    var onChange: () -> Void = {}

    private enum State {
        case pending
        case ready(String)
        case none
    }

    /// Main thread only: what each file's row should show, for the version
    /// of the file it was asked about.
    private var states: [String: (version: Date?, state: State)] = [:]

    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var queue: [(path: String, version: Date?)] = []
    private var queued: Set<String> = []
    private var finished: [(path: String, version: Date?, display: String?)] = []
    private var flushScheduled = false

    private let cacheRoot = ThumbnailCache.root
    private let linkFolder: String? = {
        guard let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
              runtime.hasPrefix("/")
        else { return nil }
        let folder = runtime + "/lava-thumbnails"
        mkdir(folder, 0o700)
        return folder
    }()

    /// Workers: a few, not one per core. A decode holds the whole picture —
    /// 96 MB for 24 megapixels — until it is scaled down, so four at once is
    /// already most of a gigabyte for a moment.
    init(workers: Int = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2))) {
        for index in 0..<workers {
            let thread = Thread { [weak self] in self?.work() }
            thread.name = "Thumbnails \(index)"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    /// The path to draw for `entry`, or nil — no thumbnail yet, or none to
    /// be had. Main thread.
    func path(for entry: FileEntry) -> String? {
        guard ThumbnailCache.wants(entry, root: cacheRoot) else { return nil }
        if let known = states[entry.path], known.version == entry.modified {
            if case .ready(let display) = known.state { return display }
            return nil
        }
        states[entry.path] = (entry.modified, .pending)
        lock.lock()
        if queued.insert(entry.path).inserted {
            queue.append((entry.path, entry.modified))
            wake.signal()
        }
        lock.unlock()
        return nil
    }

    /// Drops queued work for anything outside `folders` — the folders still
    /// on screen. A decode already running finishes; its answer is kept.
    func retain(folders: Set<String>) {
        lock.lock()
        let dropped = queue.filter { !folders.contains(Self.folder(of: $0.path)) }
        queue.removeAll { !folders.contains(Self.folder(of: $0.path)) }
        for job in dropped { queued.remove(job.path) }
        lock.unlock()
        guard !dropped.isEmpty else { return }
        // Forgotten, so coming back asks again rather than waiting on a job
        // that is no longer queued.
        let paths = dropped.map(\.path)
        MainQueue.async { [weak self] in
            guard let self else { return }
            for path in paths {
                if case .pending? = self.states[path]?.state { self.states[path] = nil }
            }
        }
    }

    // MARK: Workers

    private func work() {
        while true {
            wake.wait()
            lock.lock()
            guard let job = queue.popLast() else {
                lock.unlock()
                continue
            }
            queued.remove(job.path)
            lock.unlock()
            let display = thumbnail(of: job.path)
            deliver(job.path, job.version, display)
        }
    }

    /// The thumbnail's display path, made if it has to be. Nil when the
    /// picture will not decode.
    private func thumbnail(of path: String) -> String? {
        guard let stamp = ThumbnailCache.Stamp(ofFileAt: path) else { return nil }
        let normal = ThumbnailCache.path(for: path, size: .normal, root: cacheRoot)
        if ThumbnailCache.isValid(thumbnail: normal, of: path, stamp: stamp) {
            return display(normal, stamp: stamp)
        }
        let failure = ThumbnailCache.failurePath(for: path, root: cacheRoot)
        if ThumbnailCache.isValid(thumbnail: failure, of: path, stamp: stamp) { return nil }

        let size = ThumbnailCache.Size.normal.pixels
        guard let decoded = Editor.decodeImage(path: path, maxPixelSize: size),
              let png = Editor.encodePng(
                  pixels: decoded.pixels, width: decoded.width, height: decoded.height,
                  maxSide: size
              )
        else {
            recordFailure(at: failure, of: path, stamp: stamp)
            return nil
        }
        do {
            try ThumbnailCache.write(png: png, to: normal, of: path, stamp: stamp)
        } catch {
            // A cache that cannot be written — a read-only home, a full disk —
            // still has a thumbnail to show this once; it just is not kept.
            return nil
        }
        return display(normal, stamp: stamp)
    }

    /// The standard's failure record is a PNG like any thumbnail, carrying
    /// the URI and time it failed for. One transparent pixel.
    private func recordFailure(at failure: String, of path: String, stamp: ThumbnailCache.Stamp) {
        guard let png = Editor.encodePng(pixels: [0, 0, 0, 0], width: 1, height: 1) else { return }
        try? ThumbnailCache.write(png: png, to: failure, of: path, stamp: stamp)
    }

    /// `thumbnail`, under a name with this version of the picture in it. See
    /// the type's comment. The cache file itself when there is no runtime
    /// folder to put a link in.
    private func display(_ thumbnail: String, stamp: ThumbnailCache.Stamp) -> String {
        guard let linkFolder else { return thumbnail }
        let name = (thumbnail as NSString).lastPathComponent.dropLast(4)
        let link = "\(linkFolder)/\(name)-\(stamp.text).png"
        if symlink(thumbnail, link) != 0, errno != EEXIST { return thumbnail }
        return link
    }

    private func deliver(_ path: String, _ version: Date?, _ display: String?) {
        lock.lock()
        finished.append((path, version, display))
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        MainQueue.async { [weak self] in self?.flush() }
    }

    /// Everything that arrived since the last flush, in one change: a folder
    /// of cached thumbnails answers dozens a millisecond, and a view rebuild
    /// per answer would be the expensive part of showing them.
    private func flush() {
        lock.lock()
        let batch = finished
        finished = []
        flushScheduled = false
        lock.unlock()
        var changed = false
        for (path, version, display) in batch {
            // An answer for a version nobody is asking about any more — the
            // file changed while it was being decoded — is dropped; the row
            // has already asked about the new one.
            guard let current = states[path], current.version == version else { continue }
            states[path] = (version, display.map(State.ready) ?? .none)
            changed = changed || display != nil
        }
        if changed { onChange() }
    }

    private static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
