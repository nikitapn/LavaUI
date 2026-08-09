import Foundation
import LavaUI
import Observation

// Two windows, one process, one GPU — as a LavaUI app rather than a hand-rolled
// loop.
//
// The engine half of this (one `RenderDevice`, two `RenderWindow`s, two
// swapchains, two arenas) was already there; what this exercises is the Swift
// half. `LavaApp.run` drives every open window, and `LavaApp.openWindow` opens
// one from a button handler with its own view tree, so a second window is a
// closure rather than a second copy of the frame loop.
//
// Three things worth watching, because each was a process-global that had to
// become per window (see `WindowScope`):
//
//   - **Invalidation.** Nothing here marks anything dirty. Both roots read the
//     same `@Observable` model, so a click in one window repaints the other
//     through observation alone — and only the windows that actually read what
//     changed.
//   - **Focus.** Each window has a text field. Type in one, click to the other,
//     click back: the caret is where you left it, and keystrokes never cross.
//   - **Visibility.** The spinner in a window keeps animating while the other
//     window is minimized, and stops when its own is.

/// State every window reads and any window can write.
///
/// `@Observable`, not manual dirty flags: a window repaints because one of its
/// bodies read a property that changed, which is exactly the behaviour a
/// multi-window app needs and the thing that is tedious to maintain by hand.
@Observable
final class Counter {
    var count = 0
    var lastTouched = "nobody yet"

    func bump(by n: Int, from who: String) {
        count += n
        lastTouched = who
    }
}

nonisolated(unsafe) let model = Counter()

let editorOpt = LavaApp.open(
    title: "Window A · counter", width: 560, height: 420
)
guard let editor = editorOpt else {
    FileHandle.standardError.write(Data("failed to open the first window\n".utf8))
    exit(1)
}

// ─── Roots ───────────────────────────────────────────────────────────────────

struct MainWindow: View {
    let model: Counter
    @State private var note = ""
    /// Ids of the mirrors this window opened, so it can say how many are up and
    /// close them again. `LavaApp` owns the windows; this is just a tally.
    @State private var mirrors: [WindowID] = []

    var body: some View {
        VStack(padding: 12) {
            Text("Window A", color: .accent)
            Text("count = \(model.count)", color: .primary)
            Text("last touched by: \(model.lastTouched)", color: .secondary)

            Text("Add one", color: .accent, onClick: {
                model.bump(by: 1, from: "A")
            })

            Text("Open a mirror window", color: .accent, onClick: {
                openMirror()
            })
            Text("mirrors open: \(mirrors.count)", color: .secondary)

            Text("Type here, then click into a mirror:", color: .secondary)
            TextField(text: $note, placeholder: "A's field")

            Spacer()
            Text("One device, one glyph atlas —", color: .secondary)
            Text("a mirror rasterizes nothing A already did.", color: .secondary)
        }
        .padding(16)
    }

    /// Opens a window with its own tree, and prunes the tally when it goes.
    ///
    /// `onClose` fires whichever way the window went — its own button, its
    /// titlebar X, or the app shutting down — so the count cannot drift.
    private func openMirror() {
        let ordinal = mirrors.count + 1
        var opened: WindowID?
        opened = LavaApp.openWindow(
            title: "Mirror \(ordinal)",
            width: 460, height: 380,
            onClose: {
                if let id = opened { mirrors.removeAll { $0 == id } }
            },
            makeRoot: { MirrorWindow(model: model, ordinal: ordinal) }
        )
        if let opened { mirrors.append(opened) }
    }
}

struct MirrorWindow: View {
    let model: Counter
    let ordinal: Int
    @State private var note = ""

    var body: some View {
        VStack(padding: 12) {
            Text("Mirror \(ordinal)", color: .accent)
            Text("count = \(model.count)", color: .primary)
            Text("last touched by: \(model.lastTouched)", color: .secondary)

            Text("Add ten", color: .accent, onClick: {
                model.bump(by: 10, from: "Mirror \(ordinal)")
            })
            Text("Reset", color: .accent, onClick: {
                model.count = 0
                model.lastTouched = "Mirror \(ordinal)"
            })

            TextField(text: $note, placeholder: "Mirror \(ordinal)'s field")

            Spacer()
            // Closes this window without touching A or the device. The handler
            // does not need to know its own window id — it runs inside its
            // window's frame, and that is what `closeCurrentWindow` reads.
            // Reaped at the end of the frame rather than here, because freeing
            // the tree a click handler is still running in is a crash.
            Text("Close this window", color: .accent, onClick: {
                LavaApp.closeCurrentWindow()
            })
        }
        .padding(16)
    }
}

LavaApp.run(editor: editor) { MainWindow(model: model) }

FileHandle.standardError.write(Data("two-window app exited\n".utf8))
