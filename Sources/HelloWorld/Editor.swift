#if canImport(CxxCanvas)
import CxxCanvas
import Foundation

/// Swift wrapper over `canvas::Engine` — direct C++ interop, no C shim.
///
/// This used to wrap a flat `canvas::swiftEditor*` free-function API (a
/// `SwiftEditor*` opaque handle passed to every call) because Swift's C++
/// interop wouldn't import `Engine` as a class at the time. That's no longer
/// true: `Engine` has a proper move constructor (pimpl'd, non-copyable) and
/// imports cleanly, so this now just holds one and calls its methods
/// directly — no `OpaquePointer`, no `strdup`/`free`, no manually building
/// `char**` arrays for tree/property lists.
///
/// Two things `Engine`'s C++ API asks of callers that don't fit Swift
/// directly, both worked around here rather than in `Engine` itself:
///  - `std::vector<T>` can't be constructed from Swift source in this
///    toolchain (a ClangImporter limitation around `<vector>`'s `bool`
///    specialization — see canvas_engine.hpp's clear/add/commit builders).
///    `setProjectTree`/`setProperties` use those incremental builders here.
///  - `std::expected<void, Error>` (`VoidResult`)'s `.error()` accessor
///    returns a reference, which Swift's interop won't call (possible
///    dangling pointer) — so failures are surfaced as `nil`/`false` here,
///    not with the underlying message. Check stderr (Engine logs failures
///    internally) if you need to know why something failed to open.
public final class Editor: @unchecked Sendable {
    private var engine = canvas.Engine()

    private init() {}

    public static func open(
        assetsRoot: String,
        width: Int32 = 1280,
        height: Int32 = 800,
        title: String = "FBD Editor"
    ) -> Editor? {
        let editor = Editor()
        let opened = editor.engine.openWindow(
            std.string(assetsRoot), UInt32(width), UInt32(height), std.string(title)
        ).has_value()
        guard opened else { return nil }
        editor.engine.setWindowVisible(true)
        return editor
    }

    public var isOpen: Bool { engine.isOpen() }

    public func setVisible(_ v: Bool) {
        engine.setWindowVisible(v)
    }

    public func setWorkspace(_ layout: WorkspaceLayout) {
        engine.setWorkspaceColumns(
            layout.left.panelKind,
            layout.center.panelKind,
            layout.right.panelKind,
            layout.leftWidth,
            layout.rightWidth
        )
    }

    public func setProjectTree(
        ids: [String], labels: [String], depths: [Int32], selected: [Bool]
    ) {
        precondition(ids.count == labels.count
            && ids.count == depths.count
            && ids.count == selected.count)
        engine.clearProjectTreeBuilder()
        for i in ids.indices {
            engine.addTreeItem(std.string(ids[i]), std.string(labels[i]), depths[i], selected[i])
        }
        engine.commitProjectTree()
    }

    public func setProperties(keys: [String], values: [String]) {
        precondition(keys.count == values.count)
        engine.clearPropertiesBuilder()
        for i in keys.indices {
            engine.addPropertyItem(std.string(keys[i]), std.string(values[i]))
        }
        engine.commitProperties()
    }

    public func selectedTreeId() -> String {
        String(engine.selectedTreeId())
    }

    public func clearShapes() { engine.clearShapes() }
    public func clearLines() { engine.clearLines() }
    public func clearLabels() { engine.clearLabels() }

    @discardableResult
    public func addRoundedRect(
        x: Float, y: Float, w: Float, h: Float,
        r: Float, g: Float, b: Float, a: Float = 1
    ) -> Int32 {
        engine.addRoundedRect(x, y, w, h, r, g, b, a)
    }

    @discardableResult
    public func addCircle(
        cx: Float, cy: Float, radius: Float,
        r: Float, g: Float, b: Float, a: Float = 1
    ) -> Int32 {
        engine.addCircle(cx, cy, radius, r, g, b, a)
    }

    @discardableResult
    public func addLine(
        x1: Float, y1: Float, x2: Float, y2: Float,
        r: Float, g: Float, b: Float, a: Float = 1
    ) -> Int32 {
        engine.addLine(x1, y1, x2, y2, r, g, b, a)
    }

    @discardableResult
    public func addLabel(
        _ text: String, x: Float, y: Float,
        r: Float, g: Float, b: Float
    ) -> Int32 {
        engine.addLabel(std.string(text), x, y, r, g, b)
    }

    @discardableResult
    public func addTextWidget(
        x: Float, y: Float, w: Float, h: Float,
        text: String, multiline: Bool
    ) -> Int32 {
        engine.addTextWidget(x, y, w, h, std.string(text), multiline)
    }

    public func setTextWidgetFocused(_ id: Int32, _ focused: Bool) {
        engine.setTextWidgetFocused(id, focused)
    }

    @discardableResult
    public func addTextHighlight(
        id: Int32, pattern: String,
        r: Float, g: Float, b: Float, a: Float = 1, priority: Int32 = 0
    ) -> Bool {
        engine.addTextWidgetHighlightRule(id, std.string(pattern), r, g, b, a, priority)
    }

    // ─── Declarative UI ──────────────────────────────────────────────────

    public func uiReset() { engine.uiReset() }

    public func uiBegin(
        kind: UIKind, id: Int32 = 0,
        flexGrow: Float = 0, flexShrink: Float = 1,
        width: Float = -1, height: Float = -1, padding: Float = 0
    ) {
        engine.uiBegin(kind.rawValue, id, flexGrow, flexShrink, width, height, padding)
    }

    public func uiText(
        id: Int32, text: String,
        r: Float, g: Float, b: Float, clickable: Bool
    ) {
        text.withCString {
            engine.uiText(id, $0, r, g, b, clickable)
        }
    }

    public func uiEnd() { engine.uiEnd() }
    public func uiCommit() { engine.uiCommit() }

    /// Drain click (and future) events. Returns widget id + kind (0=Click).
    public func uiPollEvent() -> (widgetId: Int32, kind: Int32)? {
        var id: Int32 = 0
        var kind: Int32 = 0
        let ok = engine.uiPollEvent(&id, &kind)
        return ok ? (id, kind) : nil
    }

    /// Push a full tree and swap it in (structural hot update).
    public func commitUI(_ root: UINode, ui: UI) {
        uiReset()
        ui.push(root, into: self)
        uiCommit()
    }

    /// Poll C++ hit-test events and invoke Swift `onClick` handlers.
    public func dispatchUIEvents(ui: UI) {
        while let e = uiPollEvent() {
            if e.kind == 0 { ui.dispatch(widgetId: e.widgetId) }
        }
    }

    // ─── Phase 3 draw list ───────────────────────────────────────────────

    public func submitDrawList(_ list: DrawList) {
        // One contiguous string blob + offset table — no per-string strdup.
        list.commands.withUnsafeBufferPointer { cmdBuf in
            list.stringBlob.withUnsafeBufferPointer { blobBuf in
                list.stringOffsets.withUnsafeBufferPointer { offBuf in
                    engine.submitDrawList(
                        cmdBuf.baseAddress,
                        cmdBuf.count,
                        blobBuf.baseAddress,
                        blobBuf.count,
                        offBuf.baseAddress,
                        offBuf.count
                    )
                }
            }
        }
    }

    public func setDiagramViewport(x: Float, y: Float, w: Float, h: Float) {
        engine.setDiagramViewport(x, y, w, h)
    }

    /// Raw mouse events for Swift hit-testing.
    public func pollInputEvent() -> (kind: UInt32, x: Float, y: Float, button: Int32)? {
        var ev = canvas.InputEvent()
        guard engine.pollInputEvent(&ev) else { return nil }
        return (ev.kind, ev.x, ev.y, ev.button)
    }
}
#endif
