#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI

// Where the compositor's VRAM went.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaDebug
//
// It exists because the compositor is the only process that can answer. Every
// LavaUI surface on the desktop is rendered on one Vulkan device inside it, so
// "why is the compositor holding a gigabyte" is a question about windows a
// client cannot see, atlases it does not own and a texture cache it never
// filled. `GetGpuReport` is that answer; this draws it.
//
// A client rather than an overlay the compositor draws itself, for the same
// reason the panel is a client: the compositor should not grow a UI toolkit's
// worth of code to describe itself, and a debug window you can close, move and
// leave open on another workspace is a better tool than a keybinding that
// paints over the screen.
//
// `--once` prints the report as text and exits, which is what a script or a
// terminal wants — and what makes this usable when the desktop is too broken to
// show a window.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--once") || arguments.contains("-1") {
    guard DesktopDiagnostics.isAvailable else {
        FileHandle.standardError.write(
            Data("LavaDebug: no compositor to ask.\n".utf8))
        exit(1)
    }
    do {
        let report = try DesktopDiagnostics.gpuReport()
        print(textReport(report, verbose: arguments.contains("--verbose")))
        if arguments.contains("--dump-atlases") {
            let paths = try DesktopDiagnostics.dumpAtlasImages(
                into: GpuStore.dumpDirectory)
            for path in paths { print("wrote \(path)") }
        }
    } catch {
        FileHandle.standardError.write(
            Data("LavaDebug: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// Opaque: this is a table-shaped window, and reading numbers through the
// desktop behind them is worse, not better.
WindowBackdrop.current = .theme

guard let editor = LavaClient.open(
    title: "GPU memory", width: 940, height: 720, frame: .client
) else { exit(1) }

guard let small = UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: 13)
else {
    FileHandle.standardError.write(Data("LavaDebug: no UI font.\n".utf8))
    exit(1)
}
// A real monospace face where numbers are compared down a column, and the UI
// face when there is none — the tables stay readable either way.
//
// Registered with the editor, which is not optional: a client stamps *glyph
// ids* into its draw list and the compositor rasterises them from the face it
// has under that id. An unregistered face means the ids are looked up in
// somebody else's face, and the text comes out as its own characters shifted by
// however far the two faces disagree — which is exactly what it looked like.
let mono: UIFont = {
    guard let face = loadMonoFont(pixelSize: 12) else { return small }
    guard face.registerWithEngine(editor) else { return small }
    return face
}()

let store = GpuStore()
// Before the first frame, so the window opens with real numbers in it rather
// than a page of zeroes that fills in a second later.
store.refresh()

LavaClient.run(editor: editor) {
    DebugWindow(store: store, mono: mono, small: small)
}

#else
import Foundation

FileHandle.standardError.write(
    Data("LavaDebug needs the control plane.\n".utf8)
)
exit(1)
#endif
