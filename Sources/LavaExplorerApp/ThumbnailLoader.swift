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
/// A thumbnail to draw: where it is, and its size in pixels — which a tile
/// needs before the picture arrives, to fit the box to it rather than fit it
/// inside a box. Zero size for a picture whose size is not known (an SVG drawn
/// from its file); the whole box is then its own.
struct Thumbnail: Equatable, Sendable {
    var path: String
    var width: Float = 0
    var height: Float = 0
}

final class ThumbnailLoader: @unchecked Sendable {
    /// Called on the main queue when answers have arrived, once per batch.
    var onChange: () -> Void = {}

    private enum State {
        case pending
        case ready(Thumbnail)
        case none
    }

    /// Main thread only: what each file's row should show, for the version
    /// of the file it was asked about.
    private var states: [Key: (version: Date?, state: State)] = [:]

    /// A file at a size: the list and the icon view want different ones.
    private struct Key: Hashable {
        var path: String
        var size: ThumbnailCache.Size
    }

    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var queue: [(key: Key, version: Date?)] = []
    private var queued: Set<Key> = []
    private var finished: [(key: Key, version: Date?, display: Thumbnail?)] = []
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
    func thumbnail(for entry: FileEntry, size: ThumbnailCache.Size = .normal) -> Thumbnail? {
        guard ThumbnailCache.wants(entry, root: cacheRoot) else { return nil }
        let key = Key(path: entry.path, size: size)
        if let known = states[key], known.version == entry.modified {
            if case .ready(let display) = known.state { return display }
            return nil
        }
        states[key] = (entry.modified, .pending)
        lock.lock()
        if queued.insert(key).inserted {
            queue.append((key, entry.modified))
            wake.signal()
        }
        lock.unlock()
        return nil
    }

    /// Drops queued work for anything outside `folders` — the folders still
    /// on screen. A decode already running finishes; its answer is kept.
    func retain(folders: Set<String>) {
        lock.lock()
        let dropped = queue.filter { !folders.contains(Self.folder(of: $0.key.path)) }
        queue.removeAll { !folders.contains(Self.folder(of: $0.key.path)) }
        for job in dropped { queued.remove(job.key) }
        lock.unlock()
        guard !dropped.isEmpty else { return }
        // Forgotten, so coming back asks again rather than waiting on a job
        // that is no longer queued.
        let keys = dropped.map(\.key)
        MainQueue.async { [weak self] in
            guard let self else { return }
            for key in keys {
                if case .pending? = self.states[key]?.state { self.states[key] = nil }
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
            queued.remove(job.key)
            lock.unlock()
            let display = thumbnail(of: job.key.path, size: job.key.size)
            deliver(job.key, job.version, display)
        }
    }

    /// The thumbnail's display path, made if it has to be. Nil when the
    /// picture will not decode.
    private func thumbnail(of path: String, size: ThumbnailCache.Size) -> Thumbnail? {
        guard let stamp = ThumbnailCache.Stamp(ofFileAt: path) else { return nil }
        let cached = ThumbnailCache.path(for: path, size: size, root: cacheRoot)
        if ThumbnailCache.isValid(thumbnail: cached, of: path, stamp: stamp) {
            return display(cached, size: size, stamp: stamp, pixels: Self.pixelSize(of: cached))
        }
        let failure = ThumbnailCache.failurePath(for: path, root: cacheRoot)
        if ThumbnailCache.isValid(thumbnail: failure, of: path, stamp: stamp) { return nil }

        let pixels = size.pixels
        guard let decoded = Editor.decodeImage(path: path, maxPixelSize: pixels),
              let png = Editor.encodePng(
                  pixels: decoded.pixels, width: decoded.width, height: decoded.height,
                  maxSide: pixels
              )
        else {
            recordFailure(at: failure, of: path, stamp: stamp)
            return nil
        }
        do {
            try ThumbnailCache.write(png: png, to: cached, of: path, stamp: stamp)
        } catch {
            // A cache that cannot be written — a read-only home, a full disk —
            // still has a thumbnail to show this once; it just is not kept.
            return nil
        }
        return display(cached, size: size, stamp: stamp, pixels: PNGText.size(of: png))
    }

    /// The first 24 bytes of a PNG, for its size.
    private static func pixelSize(of path: String) -> (width: Int, height: Int)? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 24) else { return nil }
        return PNGText.size(of: Array(head))
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
    private func display(
        _ thumbnail: String, size: ThumbnailCache.Size, stamp: ThumbnailCache.Stamp,
        pixels: (width: Int, height: Int)?
    ) -> Thumbnail {
        var shown = Thumbnail(
            path: thumbnail,
            width: Float(pixels?.width ?? 0), height: Float(pixels?.height ?? 0)
        )
        guard let linkFolder else { return shown }
        // The size is in the name: both sizes of one picture share its MD5.
        let name = (thumbnail as NSString).lastPathComponent.dropLast(4)
        let link = "\(linkFolder)/\(name)-\(size.rawValue)-\(stamp.text).png"
        if symlink(thumbnail, link) == 0 || errno == EEXIST { shown.path = link }
        return shown
    }

    private func deliver(_ key: Key, _ version: Date?, _ display: Thumbnail?) {
        lock.lock()
        finished.append((key, version, display))
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
        for (key, version, display) in batch {
            // An answer for a version nobody is asking about any more — the
            // file changed while it was being decoded — is dropped; the row
            // has already asked about the new one.
            guard let current = states[key], current.version == version else { continue }
            states[key] = (version, display.map(State.ready) ?? .none)
            changed = changed || display != nil
        }
        if changed { onChange() }
    }

    private static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
