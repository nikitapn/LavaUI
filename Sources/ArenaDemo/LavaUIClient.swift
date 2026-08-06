#if canImport(CxxCanvas) && canImport(LavaIDL)
import CxxCanvas
import Foundation
import LavaClient
import LavaIDL
import LavaUI
import NPRPC

// A real LavaUI app running as a client of the compositor.
//
// `runProducer` next door hand-writes draw commands to show what the arena
// carries; this shows that a *framework* fits through it. The view tree, the
// layout, the invalidation and the frame loop are the ones every windowed
// LavaUI app uses — `LavaApp.run` is called here unmodified — and the whole
// difference is three installs before it:
//
//   1. `openClient` instead of `open`      — no window, no GPU
//   2. `editor.resources = compositor`     — ids come from whoever draws
//   3. `editor.publishFrames(to: arena)`   — frames go to shared memory
//
// The payoff is worth stating plainly, because it is the reason for all of
// it: `kill -STOP` this process and the list still scrolls. The renderer owns
// the scroll offset against a scene node id, and moving a subtree it already
// has needs nothing from the process that published it.

/// What the client draws. Deliberately ordinary — the point is that nothing
/// here knows it is running in a different process from its pixels.
struct ClientDemoView: View {
    let editor: Editor
    @State private var rows = 60
    @State private var dropped: [String] = []

    var body: some View {
        VStack(padding: 12) {
            Text("LavaUI · compositor client", color: Theme.current.accent)
            Text(
                "pid \(getpid()) · this tree lives in another process than its pixels",
                color: Theme.current.textMuted
            )

            // Pixels this process computed, registered from memory. See the
            // view's own note — it is the one thing here that needed a new
            // call on the control plane rather than an existing one.
            GeneratedImage(editor: editor)

            // The renderer owns the window, so the renderer is what the
            // desktop drops onto — this process only learns the paths by
            // asking. `.onDrop` is the same modifier a windowed app uses.
            VStack(padding: 6) {
                Text(
                    dropped.isEmpty
                        ? "drop files here"
                        : "dropped \(dropped.count): \(dropped.joined(separator: ", "))",
                    color: dropped.isEmpty
                        ? Theme.current.textMuted
                        : Theme.current.accent
                )
            }
            .onDrop { urls in
                dropped = urls.map(\.lastPathComponent)
            }

            HStack(padding: 8) {
                // Its own view, so its own `@State`. Which subtree a change
                // recomputes is decided here, by where the state lives, and
                // not by the framework: `ViewInvalidation` tracks the
                // *composite node that read the value*, so a counter sharing a
                // view with a 560-row list recomputes the list too.
                ClickCounter()
                Button("More rows") { rows += 20 }
                Spacer()
            }

            // The one that matters. A wheel notch over this moves the subtree
            // in the renderer, against a node id, with no round trip — so it
            // keeps working while this process is stopped.
            ScrollView {
                VStack {
                    ForEach(Array(0..<rows), id: \.self) { i in
                        HStack(padding: 6) {
                            Text(
                                "row \(i)",
                                color: i % 2 == 0
                                    ? Theme.current.textPrimary
                                    : Theme.current.textSecondary
                            )
                            Spacer()
                            Text("· scrolls without me", color: Theme.current.textMuted)
                        }
                    }
                }
            }
            .flexGrow(1)
        }
    }
}

/// An image this process invented, drawn by the other one.
///
/// Registered from bytes rather than a path, which is the whole point: these
/// pixels were computed here, a moment ago, and were never a file for the
/// renderer to open. Before `RegisterImageData` the only way to get them on
/// screen was to write them to disk first and let the compositor read them
/// back — which is what `SpotifyCore` still does for cover art.
///
/// A BMP because it is the one format worth hand-writing: a 14-byte file
/// header, a 40-byte info header, and rows of BGR. The client still ships no
/// codec, and the renderer sniffs the format the same way it would for a file.
struct GeneratedImage: View {
    let editor: Editor
    @State private var version = 0

    var body: some View {
        HStack(padding: 8) {
            if let image = Self.image(version: version, editor: editor) {
                Image(image, width: .point(96), height: .point(96))
            } else {
                Text("generating…", color: Theme.current.textMuted)
            }
            VStack(padding: 4) {
                Text("generated here, drawn there", color: Theme.current.textSecondary)
                Text(
                    "no file, no path, no codec in this process",
                    color: Theme.current.textMuted
                )
                Button("Regenerate") { version += 1 }
            }
            Spacer()
        }
    }

    /// Registered once per version, cached here after.
    ///
    /// A body runs whenever anything above it changes, and this call blocks on
    /// a round trip — so the cache is not an optimization, it is what keeps a
    /// frame from containing an RPC. `ImageStore` would do the same job for a
    /// path; there is no equivalent entry point for bytes yet, and one map in
    /// a demo is not enough reason to invent one.
    nonisolated(unsafe) private static var cache: [Int: UIImage] = [:]

    private static func image(version: Int, editor: Editor) -> UIImage? {
        if let hit = cache[version] { return hit }
        let bytes = bmp(size: 96, phase: Float(version) * 0.17)
        // Blocks for a round trip, which is what `registerImage` already does
        // for a path — startup-shaped work, not per-frame work.
        guard let img = editor.resources.registerImage(data: bytes, maxPixelSize: 0)
        else { return nil }
        cache[version] = img
        return img
    }

    /// A 24-bit BMP with a plasma in it, built in memory.
    private static func bmp(size: Int, phase: Float) -> [UInt8] {
        // Rows are padded to a 4-byte boundary; at 24bpp that is only a no-op
        // when the width is a multiple of 4, and getting it wrong shears the
        // image rather than failing.
        let rowBytes = size * 3
        let padding = (4 - rowBytes % 4) % 4
        let pixelBytes = (rowBytes + padding) * size
        let fileSize = 54 + pixelBytes

        var out = [UInt8]()
        out.reserveCapacity(fileSize)

        func u16(_ v: Int) { out.append(UInt8(v & 0xff)); out.append(UInt8((v >> 8) & 0xff)) }
        func u32(_ v: Int) { u16(v & 0xffff); u16((v >> 16) & 0xffff) }

        out.append(contentsOf: Array("BM".utf8))
        u32(fileSize)
        u32(0)
        u32(54)          // pixel data starts after both headers

        u32(40)          // BITMAPINFOHEADER
        u32(size)
        u32(size)
        u16(1)           // planes
        u16(24)          // bits per pixel
        u32(0)           // no compression
        u32(pixelBytes)
        u32(2835)        // ~72 DPI, in pixels per metre
        u32(2835)
        u32(0)
        u32(0)

        for y in 0..<size {
            for x in 0..<size {
                let fx = Float(x) / Float(size)
                let fy = Float(y) / Float(size)
                let v = sin((fx + phase) * 6.28) * cos((fy - phase) * 6.28)
                let t = (v + 1) / 2
                // BGR, not RGB — the one thing about BMP that catches everyone.
                out.append(UInt8(max(0, min(255, t * 255))))
                out.append(UInt8(max(0, min(255, (1 - t) * 200 + 40))))
                out.append(UInt8(max(0, min(255, fx * 255))))
            }
            for _ in 0..<padding { out.append(0) }
        }
        return out
    }
}

/// A counter that owns its own state, so pressing it recomputes only itself.
struct ClickCounter: View {
    @State private var clicks = 0

    var body: some View {
        Button("Clicked \(clicks)×") { clicks += 1 }
    }
}

/// Runs `ClientDemoView` as a client of the compositor.
///
/// Everything this used to spell out — connect, install the resource host,
/// create the arena and the surface, pump the input stream back in — is
/// `LavaClient.run` now, so that being a client is a library feature rather
/// than something this one demo knows how to do.
func runLavaUIClient() -> Never {
    guard let editor = LavaClient.open(
        title: clientName, width: 720, height: 560
    ) else { exit(1) }
    LavaClient.run(editor: editor) { ClientDemoView(editor: editor) }
}
#endif
