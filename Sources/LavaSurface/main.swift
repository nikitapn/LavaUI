#if canImport(CxxCanvas)
import CxxCanvas
import Foundation
import LavaUI
import Observation

// A LavaUI app whose pixels are drawn by the wlroots compositor.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaSurface
//
// The tree below is an ordinary LavaUI view tree. It is laid out by Yoga, its
// text is shaped by HarfBuzz, and `LavaApp.run` drives it with the same loop
// every windowed app uses. What is different is what it does with the result:
// instead of handing the draw list to a renderer in this process, it writes it
// into shared memory that the compositor maps and replays.
//
// So this process owns no GPU, no Vulkan device, no window and no swapchain.
// It owns a view tree and a page of memory. That is the whole claim, and it is
// worth being precise about what still isn't here:
//
//   * no input. The compositor owns the window, so it owns the pointer and
//     the keyboard, and getting those back needs a channel this does not have
//     yet. Nothing below is clickable; the state changes on a timer instead,
//     which is enough to prove frames flow but is not interaction.
//   * no size negotiation. Both sides are compiled with the same numbers
//     rather than the compositor telling this one what it got.
//   * no font negotiation. Ids are assigned in registration order and both
//     processes register the same two files — see `register_client_fonts` in
//     the compositor.
//
// All three are the same missing piece: a control plane. `LavaClient` already
// speaks one over NPRPC, which is why this file exists separately rather than
// as a mode of that — it is the arena half on its own, so the arena half can
// be seen working before anything else is built on top of it.

/// Shared with the compositor's `kSurfaceWidth`/`kSurfaceHeight`.
let surfaceWidth: Float = 720
let surfaceHeight: Float = 480

/// Shared with the compositor's `arena_id()`.
let arenaID = ProcessInfo.processInfo.environment["LAVA_ARENA"] ?? "lava-surface"

/// Where the font table is left for the compositor to read.
let manifestPath: String = {
    let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
    return (dir as NSString).appendingPathComponent("lava-fonts-\(arenaID)")
}()

// ─── Font ids ───────────────────────────────────────────────────────────────

/// Records every face this process registers, so the process that owns the
/// glyph atlas can register the same ones in the same order.
///
/// A `GlyphInstance` carries a font id, and an id is an index into whichever
/// table handed it out. The arena carries the id and nothing that says what it
/// means, so without this the two tables agree only by luck — and they did
/// not: LavaUI's bootstrap loads the symbols face before the UI face, so
/// "register the obvious two in the obvious order" put the UI face at 2 on one
/// side and 0 on the other, and every glyph missed.
///
/// This is the stopgap, and it is worth naming what replaces it.
/// `Compositor.RegisterFont` over NPRPC is the same idea done properly: the
/// client *asks* the renderer for an id instead of describing its own table
/// and hoping the renderer can reproduce it. `LavaClient` already does that.
/// A file works here because both processes are on one machine and the table
/// is tiny — it is a bootstrap, not a design.
final class RecordingResources: GPUResourceHost, @unchecked Sendable {
    private let editor: Editor
    private let path: String
    private var faces: [(id: UInt32, pixelSize: Float, path: String)] = []

    init(editor: Editor, path: String) {
        self.editor = editor
        self.path = path
    }

    func registerFont(path fontPath: String, pixelSize: Float) -> UInt32? {
        // The editor is the default host — this only watches what it says.
        guard let id = editor.registerFont(path: fontPath, pixelSize: pixelSize)
        else { return nil }
        if !faces.contains(where: { $0.id == id }) {
            faces.append((id, pixelSize, fontPath))
            write()
        }
        return id
    }

    /// Rewritten in full on every new face, and renamed into place so the
    /// reader never sees half a table. The compositor re-reads on change, so a
    /// face registered after it attached still arrives.
    private func write() {
        let body = faces.sorted { $0.id < $1.id }
            .map { "\($0.id)\t\($0.pixelSize)\t\($0.path)" }
            .joined(separator: "\n") + "\n"
        let tmp = path + ".tmp"
        guard (try? body.write(toFile: tmp, atomically: false, encoding: .utf8)) != nil
        else { return }
        _ = try? FileManager.default.removeItem(atPath: path)
        _ = try? FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    // Images are not wired through the arena yet, so these are the editor's
    // answers unchanged — local ids that mean nothing to the renderer. A
    // client that draws one gets no texture rather than the wrong one.
    func registerImage(path p: String, maxPixelSize: UInt32) -> UIImage? {
        editor.registerImage(path: p, maxPixelSize: maxPixelSize)
    }

    func registerImageAsync(
        path p: String, maxPixelSize: UInt32,
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        editor.registerImageAsync(
            path: p, maxPixelSize: maxPixelSize, completion: completion
        )
    }

    func registerImage(data: [UInt8], maxPixelSize: UInt32) -> UIImage? {
        editor.registerImage(data: data, maxPixelSize: maxPixelSize)
    }

    func releaseImage(key: String) { editor.releaseImage(key: key) }
}

// ─── The app ────────────────────────────────────────────────────────────────

/// Deliberately ordinary. Nothing here knows it is running in a different
/// process from its pixels — that is the point of it being this dull.
/// What changes, so that something does.
///
/// A class rather than `@State` because the thing driving it is outside the
/// view tree — `@State` is view-local storage and cannot be reached from a
/// worker thread. Reading `frames` inside `body` is what registers the
/// dependency, so a write invalidates exactly the subtree that displayed it.
@Observable
final class Ticker {
    var frames = 0
}

/// Top-level `let`s in a `main.swift` are main-actor isolated, and the ticker
/// thread is not. Reached through a nonisolated global instead — the frame
/// loop is the only thing that ever *writes* it, because every write goes
/// through `MainQueue.async`.
nonisolated(unsafe) let ticker = Ticker()

struct SurfaceDemoView: View {
    var ticks: Int { ticker.frames }

    private var rows: [(String, Color)] {
        [
            ("shaped here, rasterised there", Theme.current.textPrimary),
            ("no Vulkan device in this process", Theme.current.textMuted),
            ("draw list written straight into shared memory", Theme.current.textMuted),
            ("frame \(ticks)", Theme.current.accent),
        ]
    }

    var body: some View {
        VStack(
            width: .point(surfaceWidth), height: .point(surfaceHeight),
            padding: 20, spacing: 14
        ) {
            Text("LavaUI · compositor surface", color: Theme.current.accent)
            Text("pid \(getpid()) · arena '\(arenaID)'", color: Theme.current.textMuted)

            VStack(padding: 14, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.0, color: row.1)
                }
            }
            .background(Theme.current.panel)
            .cornerRadius(10)

            // Shapes as well as text, so a frame that arrives with a broken
            // glyph atlas still looks different from one that never arrived —
            // and so the moving one shows at a glance that frames are flowing.
            HStack(padding: 0, spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    VStack(width: .point(44), height: .point(44)) {}
                        // Explicit rather than theme tokens: this is a test
                        // instrument, and it has to stay legible against
                        // whatever the theme does.
                        .background(
                            i == ticks % 6
                                ? Color(r: 0.98, g: 0.62, b: 0.15)
                                : Color(r: 0.16, g: 0.18, b: 0.24)
                        )
                        .cornerRadius(8)
                }
            }
        }
        .background(Theme.current.background)
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// `Editor.openClient` rather than `LavaApp.openClient`, and the difference is
// the whole reason: the latter bootstraps fonts for you, which is exactly one
// step too early — the recording host has to be installed *before* anything
// registers a face, or the first faces are assigned ids nobody wrote down.
guard let editor = Editor.openClient(width: surfaceWidth, height: surfaceHeight) else {
    FileHandle.standardError.write(Data("failed to open the client engine\n".utf8))
    exit(1)
}
let resources = RecordingResources(editor: editor, path: manifestPath)
editor.resources = resources
guard FontStore.bootstrap(
    assetsRoot: LavaResources.root, pixelSize: 16, into: editor
) != nil else {
    FileHandle.standardError.write(Data("no UI face under \(LavaResources.root)\n".utf8))
    exit(1)
}

// Creating the arena is what the compositor is waiting for — it retries
// attaching until this succeeds, so the two can start in either order.
guard let sink = ArenaFrameSink(id: arenaID) else {
    FileHandle.standardError.write(
        Data("failed to create arena '\(arenaID)' — is another client running?\n".utf8)
    )
    exit(1)
}
editor.publishFrames(to: sink)
let uiID: String = FontStore.default.map { String($0.engineId) } ?? "nil"
let banner = "arena '\(arenaID)' created (\(sink.mappedBytes / 1024) KiB), "
    + "UI face id \(uiID), fonts listed in \(manifestPath)\n"
FileHandle.standardError.write(Data(banner.utf8))

// The only thing driving change, because there is no input yet. A real client
// is woken by the pointer, the keyboard, or its own work finishing; this one
// has none of those, so it ticks. `MainQueue.async` is what makes that safe
// from another thread — it hands the mutation to the frame loop and wakes it.
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        MainQueue.async { ticker.frames += 1 }
    }
}

LavaApp.run(editor: editor) { SurfaceDemoView() }
#else
print("LavaSurface needs CxxCanvas (Linux).")
#endif
