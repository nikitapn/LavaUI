import Foundation
import LavaPDFCore
import LavaUI

/// The rendered tiles, and the workers that render them.
///
/// Two halves with one rule between them. The *resident* set — tiles that are
/// textures now — belongs to the main thread: paint reads it, and only the
/// main thread adds to or evicts from it. The *queue* and what the workers are
/// busy with are shared, under `lock`, because both sides touch them. A worker
/// never sees the resident set and never needs to: the main thread only asks
/// for tiles it does not have.
///
/// The queue is replaced, not appended to, every time paint asks. That is the
/// whole of cancellation: a fast scroll asks for a new set of tiles every
/// frame, and what it asked for a frame ago and has scrolled past simply
/// stops being in the queue. A batch already being rendered finishes and is
/// kept — it is probably still useful, and poppler cannot be interrupted from
/// the C++ API anyway.
final class TileStore: @unchecked Sendable {
    private struct Entry {
        let image: UIImage
        let bytes: Int
        var lastUsed: UInt64
    }

    /// What the textures may add up to before the least recently drawn go.
    /// A full tile is 1 MiB, so this is a few screenfuls at any zoom, and the
    /// zoom the user just left.
    static let budgetBytes = 256 * 1024 * 1024

    private let host: any GPUResourceHost
    /// Whether textures may be made from a worker. A compositor's host is a
    /// round trip from any thread; the built-in renderer uploads to a device
    /// only the main thread may touch — see `GPUResourceHost.uploadPixels`.
    private let uploadsOffMain: Bool

    // Main thread only.
    private var resident: [TileKey: Entry] = [:]
    private var byPage: [Int: Set<TileKey>] = [:]
    private var residentBytes = 0
    private var frame: UInt64 = 0

    // Shared, under `lock`.
    private let lock = NSCondition()
    private var queue: [TileBatch] = []
    private var rendering: Set<TileKey> = []
    private var documents: [PDFDocument] = []
    /// Bumped when the document changes, so a batch of the old one that
    /// lands afterwards is thrown away rather than drawn on the new one.
    private var generation = 0
    private var workers: [Thread] = []
    private var stopped = false

    init(host: any GPUResourceHost, uploadsOffMain: Bool, workers count: Int) {
        self.host = host
        self.uploadsOffMain = uploadsOffMain
        for index in 0..<count {
            let thread = Thread { [weak self] in self?.work(index) }
            thread.name = "pdf-render-\(index)"
            thread.qualityOfService = .userInitiated
            workers.append(thread)
        }
        workers.forEach { $0.start() }
    }

    var workerCount: Int { workers.count }

    /// Points the workers at a new file — one `PDFDocument` each, because
    /// poppler renders one page of a document at a time — and drops every
    /// tile of the old one.
    func reset(documents next: [PDFDocument]) {
        lock.lock()
        generation += 1
        queue.removeAll()
        rendering.removeAll()
        documents = next
        lock.unlock()
        for entry in resident.values { host.releaseImage(key: entry.image.cacheKey) }
        resident.removeAll()
        byPage.removeAll()
        residentBytes = 0
    }

    // ─── Paint's side ────────────────────────────────────────────────────

    /// Starts a frame. Tiles drawn from here on count as used by it.
    func beginFrame() { frame += 1 }

    func has(_ key: TileKey) -> Bool { resident[key] != nil }

    /// The resident tiles of `page`, furthest from `scaleKey` first — the
    /// order to draw them in, so the tiles of the zoom on screen land on top
    /// of whatever stands in for them: a preview below, and the zoom just left
    /// in either direction. Marks each as used this frame.
    func tiles(ofPage page: Int, nearest scaleKey: Int) -> [(key: TileKey, image: UIImage)] {
        guard let keys = byPage[page] else { return [] }
        var result: [(key: TileKey, image: UIImage)] = []
        result.reserveCapacity(keys.count)
        for key in keys {
            guard var entry = resident[key] else { continue }
            entry.lastUsed = frame
            resident[key] = entry
            result.append((key, entry.image))
        }
        return result.sorted {
            (-abs($0.key.scaleKey - scaleKey), $0.key.row, $0.key.column)
                < (-abs($1.key.scaleKey - scaleKey), $1.key.row, $1.key.column)
        }
    }

    /// What this frame wants, most wanted first. Replaces whatever was queued.
    func want(_ keys: [TileKey], sizes: [PageSize]) {
        let missing = keys.filter { resident[$0] == nil }
        lock.lock()
        let busy = rendering
        let batches = TileGrid.batches(
            for: missing.filter { !busy.contains($0) },
            sizes: { sizes.indices.contains($0) ? sizes[$0] : PageSize(width: 612, height: 792) }
        )
        queue = batches
        if !batches.isEmpty { lock.broadcast() }
        lock.unlock()
    }

    /// Whether any of `keys` is still on its way — paint's cue to keep
    /// the "rendering" state up rather than draw an empty page as finished.
    func isPending(_ keys: [TileKey]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.contains { rendering.contains($0) } || queue.contains { batch in
            batch.tiles.contains { keys.contains($0) }
        }
    }

    // ─── The workers ─────────────────────────────────────────────────────

    private func work(_ index: Int) {
        while true {
            lock.lock()
            while !stopped && (queue.isEmpty || documents.count <= index) { lock.wait() }
            if stopped {
                lock.unlock()
                return
            }
            let batch = queue.removeFirst()
            let document = documents[index]
            let generation = self.generation
            rendering.formUnion(batch.tiles)
            lock.unlock()

            let size = document.pageSizes[batch.page]
            let pixels = document.render(
                page: batch.page, scale: TileGrid.scale(ofKey: batch.scaleKey),
                x: batch.x, y: batch.y, width: batch.width, height: batch.height
            )
            deliver(batch, pixels: pixels, size: size, generation: generation)
        }
    }

    /// Cuts the batch's window into its tiles and makes each a texture — here
    /// when the host allows it, on the main thread when it does not.
    private func deliver(
        _ batch: TileBatch, pixels: RenderedPixels?, size: PageSize, generation: Int
    ) {
        guard let pixels else {
            // A page poppler will not render. Forget the tiles, so they are
            // asked for again rather than stuck "rendering" for ever; the page
            // stays paper meanwhile.
            lock.lock()
            rendering.subtract(batch.tiles)
            lock.unlock()
            return
        }
        if uploadsOffMain {
            let uploaded = batch.tiles.compactMap { key in
                upload(key, from: pixels, batch: batch, size: size).map { (key, $0) }
            }
            MainQueue.async { self.install(uploaded, batch: batch, generation: generation) }
        } else {
            MainQueue.async {
                let uploaded = batch.tiles.compactMap { key in
                    self.upload(key, from: pixels, batch: batch, size: size).map { (key, $0) }
                }
                self.install(uploaded, batch: batch, generation: generation)
            }
        }
    }

    /// One tile out of the window, with no copy: the region starts inside the
    /// window's buffer and keeps the window's stride, which `uploadPixels`
    /// takes as given.
    private func upload(
        _ key: TileKey, from pixels: RenderedPixels, batch: TileBatch, size: PageSize
    ) -> UIImage? {
        let rect = TileGrid.pixelRect(of: key, size: size)
        let dx = rect.x - batch.x, dy = rect.y - batch.y
        guard rect.width > 0, rect.height > 0, dx >= 0, dy >= 0,
              dx + rect.width <= pixels.width, dy + rect.height <= pixels.height
        else { return nil }
        return pixels.bytes.withUnsafeBytes { buffer in
            let start = dy * pixels.stride + dx * 4
            let length = (rect.height - 1) * pixels.stride + rect.width * 4
            return host.uploadPixels(
                UnsafeRawBufferPointer(rebasing: buffer[start..<(start + length)]),
                width: UInt32(rect.width), height: UInt32(rect.height),
                stride: UInt32(pixels.stride), format: .bgrx8
            )
        }
    }

    /// Main thread: the tiles become resident, and the frame that shows them
    /// is asked for.
    private func install(_ uploaded: [(TileKey, UIImage)], batch: TileBatch, generation: Int) {
        lock.lock()
        let current = generation == self.generation
        rendering.subtract(batch.tiles)
        lock.unlock()
        guard current else {
            for (_, image) in uploaded { host.releaseImage(key: image.cacheKey) }
            return
        }
        for (key, image) in uploaded {
            if let old = resident[key] {
                host.releaseImage(key: old.image.cacheKey)
                residentBytes -= old.bytes
            }
            let bytes = Int(image.pixelWidth) * Int(image.pixelHeight) * 4
            resident[key] = Entry(image: image, bytes: bytes, lastUsed: frame)
            byPage[key.page, default: []].insert(key)
            residentBytes += bytes
        }
        evict()
        ViewInvalidation.markNeedsRedraw()
    }

    /// Down to the budget, least recently drawn first. Never a tile the last
    /// frame drew: what is on screen stays, even over budget, because the
    /// alternative is a page that blinks out while you read it.
    private func evict() {
        guard residentBytes > Self.budgetBytes else { return }
        let victims = resident
            .filter { $0.value.lastUsed < frame }
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, entry) in victims {
            guard residentBytes > Self.budgetBytes else { break }
            host.releaseImage(key: entry.image.cacheKey)
            resident[key] = nil
            byPage[key.page]?.remove(key)
            residentBytes -= entry.bytes
        }
    }
}
