#if canImport(CxxCanvas) && canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

// The desktop's top panel, as an ordinary LavaUI client.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaTaskbar
//   terminal 3:  swift run LavaSurface
//
// Nothing here is privileged. It publishes draw lists into a shared arena and
// reads input off a stream, exactly like the app next to it — the only
// difference is one call at startup: `openPanel` instead of `open`, which asks
// the compositor for a surface docked to an edge rather than a window placed
// wherever it likes.
//
// That is the whole reason the panel role went into the IDL rather than being
// a compositor built-in. A shell written as a client is a shell that can be
// replaced, restarted, and debugged like anything else — and one that proves
// the client API is complete enough to build a desktop with, which a built-in
// would have quietly avoided answering.
//
// What it does not have yet, and why:
//
//   * no window list. The compositor knows which surfaces exist; the panel
//     does not, and there is no call that would tell it. That is the next
//     piece of the control plane, and it is what minimize is waiting for.
//   * no global menu. LavaUI apps can already export one over DBus
//     (`appMenuAttach`), so the panel would consume it the same way a GNOME
//     panel does — a separate channel from this one entirely.

/// Refreshed on a timer, because a clock is the one thing on a panel that
/// changes without anybody touching it.
@Observable
final class Clock {
    var text = ""

    func tick() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM  HH:mm:ss"
        text = formatter.string(from: now)
    }
}

nonisolated(unsafe) let clock = Clock()

struct TaskbarView: View {
    var body: some View {
        HStack(padding: 10, alignment: .center, spacing: 16) {
            Text("Lava", color: Theme.current.accent)

            // Stands in for the window list until there is a call that would
            // provide one. Deliberately not faked from anything local: the
            // panel genuinely cannot know, and pretending would hide that.
            Text("no window list yet", color: Theme.current.textDim)

            // Pushes the clock to the far end: an empty growing child is the
            // spacer, since the stack distributes leftover space by flex.
            HStack(flexGrow: 1, padding: 0) {}

            Text(clock.text, color: Theme.current.textPrimary)
        }
        .background(Theme.current.panel)
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Opaque: a panel is a background, and seeing the desktop through it would
// make everything on it harder to read. `.color(…)` rather than `.theme` only
// so the panel is a shade apart from the windows in front of it.
WindowBackdrop.current = .color(Theme.current.panel)

guard let editor = LavaClient.openPanel(
    title: "Lava Panel", edge: .top, thickness: 32, reserve: true
) else { exit(1) }

Thread.detachNewThread {
    while true {
        MainQueue.async { clock.tick() }
        Thread.sleep(forTimeInterval: 1.0)
    }
}

LavaClient.run(editor: editor) { TaskbarView() }
#else
print("LavaTaskbar needs CxxCanvas and the NPRPC control plane (Linux).")
#endif
