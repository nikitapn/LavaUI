import Foundation
import LavaClient
import LavaShotCore
import LavaUI

/// LavaShot — the screen, frozen, with something drawn on it.
///
/// Runs, photographs the desktop, and covers it with the photograph. What
/// follows is on a picture, not on the desktop: the windows underneath are
/// still there and still running, and nothing that happens here touches them.
///
/// The order matters and is the whole trick. The window has to exist before it
/// can ask the compositor for anything, so by the time the capture is taken
/// this window is already on screen — which is why the capture leaves it out
/// (`CaptureScreen(includeSelf: false)`). The alternative, capturing before
/// mapping, would mean a client that is half-started, and it is not clear when
/// "before" ends.
@main
struct LavaShotApp {
    static func main() {
        AppSettings.configure(appName: "LavaShot")

        guard let editor = LavaClient.open(
            title: "LavaShot", frame: .client, fillScreen: .output
        ) else { exit(1) }
        Theme.current = .nebula

        // Before the first frame: a label typed into a face that is still
        // loading draws at the wrong size and jumps when it arrives.
        Fonts.warm()

        let session = ShotSession(editor: editor)
        session.onQuit { [session] in
            // The temporary file the shot was read from goes with the window.
            // Nothing else will ever name it — the texture was uploaded when
            // it was registered and does not need the file again.
            session.discard()
            editor.requestClose()
        }

        LavaClient.run(
            editor: editor,
            onRawKey: { event in keys(event, session: session) },
            makeRoot: { ShotView(session: session) }
        )
    }

    /// Escape cancels, Enter or Ctrl+C copies, Ctrl+S saves, Ctrl+Shift+S asks
    /// where.
    ///
    /// Raw rather than through `FocusManager` because nothing here is a
    /// text field: the canvas is not focusable and the toolbar is a row of
    /// glyphs, and a screenshot overlay that needed to be clicked before it
    /// answered the keyboard would be one nobody could cancel.
    private static func keys(_ event: InputEvent, session: ShotSession) -> Bool {
        // `x > 0` is a press; releases repeat the same key and would fire
        // everything twice.
        guard event.x > 0 else { return false }
        let mods = Int32(event.y)
        let control = (mods & KeyMods.control) != 0
        let shift = (mods & KeyMods.shift) != 0

        // A label owns the keyboard while it is open, and it has to: `r`, `e`
        // and `a` are tool shortcuts the rest of the time, and a tool that
        // switched tools while somebody typed "arrow" would be unusable. Only
        // chords get past it — Ctrl+Z, Ctrl+C. The first Escape closes the
        // label, the second leaves.
        if session.editKey(event.button, control: control) { return true }

        switch event.button {
        case KeyCode.escape:
            session.perform(.cancel)
        case KeyCode.enter:
            session.perform(.copy)
        case KeyCode.c where control:
            session.perform(.copy)
        case KeyCode.s where control && shift:
            session.saveAs()
        case KeyCode.s where control:
            session.perform(.save)
        case KeyCode.z where control && shift:
            session.perform(.redo)
        case KeyCode.z where control:
            session.perform(.undo)
        case KeyCode.y where control:
            session.perform(.redo)
        // The tools, in the order they sit on the bar. Single letters, because
        // this window owns the keyboard for as long as it is up, and outside
        // an open label there is nothing to type into.
        case KeyCode.t: session.perform(.tool(.text))
        case KeyCode.r: session.perform(.tool(.rectangle))
        case KeyCode.e: session.perform(.tool(.ellipse))
        case KeyCode.a: session.perform(.tool(.arrow))
        case KeyCode.p: session.perform(.tool(.pen))
        case KeyCode.h: session.perform(.tool(.highlight))
        case KeyCode.b: session.perform(.tool(.blur))
        case KeyCode.v: session.perform(.tool(.select))
        default:
            return false
        }
        return true
    }

}
