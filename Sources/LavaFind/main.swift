#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaUI

// LavaFind: search the files on this machine by name.
//
//   Mod+Space, or: swift run LavaFind
//
// The window over `lava-index` (indexer/, idl/index.npidl), which does all the
// finding; this asks it and draws the answer. Spawned per use and gone once a
// file is opened or the window is dismissed, like the launcher — and for the
// same reason: a client is on screen in ~200 ms, and nothing is worth holding
// a surface for the rest of the time.
//
// No index, no search: when the daemon is not running the window says so and
// how to start it, rather than walking the disk itself, which is the job the
// daemon exists to have done already.

// Clear, so the screen around the card is the desktop. The card and the bar
// paint their own surfaces.
WindowBackdrop.current = .none

// Full-screen and frameless, like the launcher: the card is placed by layout,
// a third of the way down, and a click anywhere else lands on this surface
// and closes it. A window the size of the card would need the compositor to
// place it, and a click outside it would go to whatever was underneath.
guard let editor = LavaClient.open(
    title: "Find", frame: .client, fillScreen: .maximized
) else { exit(1) }

FindFonts.small = UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: 13)
FindFonts.mono = {
    // Registered with the editor or the glyph ids are looked up in some other
    // face on the compositor's side — see LavaDebug's `mono`.
    guard let face = loadMonoFont(pixelSize: 13), face.registerWithEngine(editor) else {
        return FindFonts.small
    }
    // The footer's ↵ and ↑↓ are not in every coding face. Named, not loaded:
    // each is read the first time a character misses the faces ahead of it.
    face.useFallbacks(UIFont.monospaceFallbacks(pixelSize: 13), into: editor)
    return face
}()

model.start()

LavaClient.run(editor: editor, onRawKey: handleKey) { FindView() }

/// A monospace face for paths, badges and sizes, where columns line up.
func loadMonoFont(pixelSize: Float) -> UIFont? {
    let candidates = [
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
        "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        if let font = UIFont(path: path, pixelSize: pixelSize) { return font }
    }
    return nil
}

#else
import Foundation

FileHandle.standardError.write(Data("LavaFind needs the control plane.\n".utf8))
exit(1)
#endif
