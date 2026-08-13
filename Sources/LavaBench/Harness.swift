import Foundation
import LavaUI

/// Drives the real frame pipeline — `LayoutHost.setRoot` → `calculateLayout`
/// → `DrawList.emitTree` — with no event loop and no present.
///
/// **Why a window is still open.** Fonts are shaped by the engine and the
/// draw list writes into engine-owned storage, so text measurement — the
/// thing every editor benchmark here is actually about — does not exist
/// without an `Editor`. The window is opened and then ignored: nothing is
/// presented, no events are pumped, and the benchmark never touches the
/// swapchain. That is deliberate. Present time is dominated by vsync, which
/// would put a 16 ms floor under every measurement and hide exactly the
/// CPU-side costs this suite exists to catch.
///
/// **Why not the agent server.** Driving the app through `mcp__lava-ui__*`
/// or xdotool measures the same code, but the numbers arrive as scraped log
/// lines with a human-scale click in the middle of them, and `settle()`
/// renders outside the instrumented block, so agent-driven frames print no
/// timing at all. This calls the same three functions the run loop calls,
/// directly, and can therefore repeat one of them a hundred times.
final class Harness {
    let editor: Editor
    private(set) var host = LayoutHost()
    let drawList: DrawList

    var viewportW: Float = 1280
    var viewportH: Float = 800

    /// Scratch directory for fixtures a scenario needs on disk (poster PNGs).
    let scratch: URL

    init(editor: Editor, scratch: URL) {
        self.editor = editor
        self.drawList = DrawList(editor: editor)
        self.scratch = scratch
    }

    /// New retained tree for the next repetition.
    ///
    /// A fresh `LayoutHost` rather than a re-`setRoot`, because those are two
    /// different things being measured: `setRoot` on an existing host
    /// *reconciles* (the steady-state path), while a new host *mounts* (the
    /// path a disclosure toggle takes, and the one that was 601 ms). A
    /// scenario that wants the reconcile cost measures it explicitly by
    /// mounting in `prepare` and calling `mount` again in `body`.
    func resetTree() {
        host = LayoutHost()
        _ = ViewInvalidation.consume()
    }

    func mount<V: View>(_ view: V) {
        host.setRoot(view)
    }

    @discardableResult
    func layout() -> Int {
        host.calculateLayout(width: viewportW, height: viewportH).count
    }

    func emit() {
        guard let root = host.rootNode else { return }
        // What a frame does before emitting (see `LavaWindow.renderFrame`).
        // Without it this list is shared by every scenario in the process and
        // never emptied, so a `drawCommands` counter reads as the running
        // total of everything benched so far — order-dependent, and moved by
        // changes to scenarios it has nothing to do with.
        drawList.clear()
        drawList.emitTree(
            root, originX: 0, originY: 0,
            viewportW: viewportW, viewportH: viewportH
        )
    }

    /// The three stages the frame loop runs for a `.body` invalidation, timed
    /// under the same names `LAVAUI_DEBUG=1` prints.
    func frame<V: View>(_ view: V, into rec: Recorder) {
        rec.stage("body") { mount(view) }
        rec.stage("layout") { layout() }
        rec.stage("emit") { emit() }
    }

    /// A `.redraw` frame: emit only, which is what a caret blink or an
    /// arriving cover image costs. Skipping body and layout is not an
    /// approximation — `renderFrame(.redraw)` genuinely skips both.
    func redraw(into rec: Recorder) {
        rec.stage("emit") { emit() }
    }
}
