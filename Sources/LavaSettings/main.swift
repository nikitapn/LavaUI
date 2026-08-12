#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI

// The desktop's settings, as an ordinary client of it.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaSettings
//
// Nothing here is privileged. It reads and writes the same control plane every
// other client has, and it is the first app that needed the *other* direction:
// until now the interface answered questions about the desktop, and this one
// changes it. That is why `SetAppearance`, `SetKeyboard` and `SetOutput` exist,
// and why each of them applies to the running compositor before it writes the
// config file — a settings app that could only edit a file and ask for a
// reload would be a text editor with worse ergonomics.
//
// Two things about the window are deliberate:
//
//   * `frame: .client`. No compositor title bar, so the page list starts at the
//     top of the window and the three controls sit in the corner above it.
//   * the root is a drag region. Without a title bar something has to move the
//     window, and the cheapest honest answer is "anywhere that is not a
//     control" — the hit test reaches children first, so nothing is stolen
//     from the sliders.

// Opaque: this is a document-shaped window, and reading a settings page
// through the desktop behind it is worse, not better.
WindowBackdrop.current = .theme

guard let editor = LavaClient.open(
    title: "Settings", width: 900, height: 640, frame: .client
) else { exit(1) }

let store = SettingsStore()
// After `open`, so there is a compositor to ask; before `run`, so the first
// frame already has the desktop's real values in it rather than the defaults
// this process happened to start with.
store.loadCore()

LavaClient.run(editor: editor) { SettingsWindow(store: store) }

#else
import Foundation

FileHandle.standardError.write(
    Data("LavaSettings needs the control plane.\n".utf8)
)
exit(1)
#endif
