#if canImport(CxxCanvas)
import CxxCanvas
import Foundation

/// Swift wrapper over `canvas::swiftEditor*` free functions (C++ interop).
///
/// The C++ `struct SwiftEditor` is incomplete in the public header, so Swift
/// imports `SwiftEditor*` as `OpaquePointer`. We pass that handle straight
/// through — no typed pointer casts.
public final class Editor: @unchecked Sendable {
    /// Opaque `canvas::SwiftEditor*`.
    private let handle: OpaquePointer

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func open(
        assetsRoot: String,
        width: Int32 = 1280,
        height: Int32 = 800,
        title: String = "FBD Editor"
    ) -> Editor? {
        let p = assetsRoot.withCString { a in
            title.withCString { t in
                canvas.swiftEditorCreate(a, width, height, t)
            }
        }
        guard let p else { return nil }
        return Editor(handle: p)
    }

    deinit {
        canvas.swiftEditorDestroy(handle)
    }

    public var isOpen: Bool { canvas.swiftEditorIsOpen(handle) }

    public func setVisible(_ v: Bool) {
        canvas.swiftEditorSetVisible(handle, v)
    }

    public func setWorkspace(_ layout: WorkspaceLayout) {
        canvas.swiftEditorSetWorkspaceColumns(
            handle,
            layout.left.rawValue,
            layout.center.rawValue,
            layout.right.rawValue,
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
        var idOwned: [UnsafeMutablePointer<CChar>] = []
        var labelOwned: [UnsafeMutablePointer<CChar>] = []
        defer {
            idOwned.forEach { free($0) }
            labelOwned.forEach { free($0) }
        }
        var idPtrs: [UnsafePointer<CChar>?] = []
        var labelPtrs: [UnsafePointer<CChar>?] = []
        for i in ids.indices {
            let ip = strdup(ids[i])!
            let lp = strdup(labels[i])!
            idOwned.append(ip)
            labelOwned.append(lp)
            idPtrs.append(UnsafePointer(ip))
            labelPtrs.append(UnsafePointer(lp))
        }
        var d = depths
        var s = selected
        idPtrs.withUnsafeMutableBufferPointer { idBuf in
            labelPtrs.withUnsafeMutableBufferPointer { labBuf in
                d.withUnsafeMutableBufferPointer { dBuf in
                    s.withUnsafeMutableBufferPointer { sBuf in
                        canvas.swiftEditorSetProjectTree(
                            handle,
                            idBuf.baseAddress,
                            labBuf.baseAddress,
                            dBuf.baseAddress,
                            sBuf.baseAddress,
                            Int32(ids.count)
                        )
                    }
                }
            }
        }
    }

    public func setProperties(keys: [String], values: [String]) {
        precondition(keys.count == values.count)
        var kOwned: [UnsafeMutablePointer<CChar>] = []
        var vOwned: [UnsafeMutablePointer<CChar>] = []
        defer {
            kOwned.forEach { free($0) }
            vOwned.forEach { free($0) }
        }
        var kPtrs: [UnsafePointer<CChar>?] = []
        var vPtrs: [UnsafePointer<CChar>?] = []
        for i in keys.indices {
            let k = strdup(keys[i])!
            let v = strdup(values[i])!
            kOwned.append(k)
            vOwned.append(v)
            kPtrs.append(UnsafePointer(k))
            vPtrs.append(UnsafePointer(v))
        }
        kPtrs.withUnsafeMutableBufferPointer { kb in
            vPtrs.withUnsafeMutableBufferPointer { vb in
                canvas.swiftEditorSetProperties(
                    handle, kb.baseAddress, vb.baseAddress, Int32(keys.count)
                )
            }
        }
    }

    public func selectedTreeId() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = canvas.swiftEditorSelectedTreeId(handle, &buf, 256)
        guard n > 0 else { return "" }
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func clearShapes() { canvas.swiftEditorClearShapes(handle) }
    public func clearLines() { canvas.swiftEditorClearLines(handle) }
    public func clearLabels() { canvas.swiftEditorClearLabels(handle) }

    @discardableResult
    public func addRoundedRect(
        x: Float, y: Float, w: Float, h: Float,
        r: Float, g: Float, b: Float, a: Float = 1
    ) -> Int32 {
        canvas.swiftEditorAddRoundedRect(handle, x, y, w, h, r, g, b, a)
    }

    @discardableResult
    public func addCircle(
        cx: Float, cy: Float, radius: Float,
        r: Float, g: Float, b: Float, a: Float = 1
    ) -> Int32 {
        canvas.swiftEditorAddCircle(handle, cx, cy, radius, r, g, b, a)
    }

    @discardableResult
    public func addLine(
        x1: Float, y1: Float, x2: Float, y2: Float,
        r: Float, g: Float, b: Float, a: Float = 1
    ) -> Int32 {
        canvas.swiftEditorAddLine(handle, x1, y1, x2, y2, r, g, b, a)
    }

    @discardableResult
    public func addLabel(
        _ text: String, x: Float, y: Float,
        r: Float, g: Float, b: Float
    ) -> Int32 {
        text.withCString { canvas.swiftEditorAddLabel(handle, $0, x, y, r, g, b) }
    }

    @discardableResult
    public func addTextWidget(
        x: Float, y: Float, w: Float, h: Float,
        text: String, multiline: Bool
    ) -> Int32 {
        text.withCString {
            canvas.swiftEditorAddTextWidget(handle, x, y, w, h, $0, multiline)
        }
    }

    public func setTextWidgetFocused(_ id: Int32, _ focused: Bool) {
        canvas.swiftEditorSetTextWidgetFocused(handle, id, focused)
    }

    @discardableResult
    public func addTextHighlight(
        id: Int32, pattern: String,
        r: Float, g: Float, b: Float, a: Float = 1, priority: Int32 = 0
    ) -> Bool {
        pattern.withCString {
            canvas.swiftEditorAddTextHighlight(handle, id, $0, r, g, b, a, priority)
        }
    }

    // ─── Declarative UI ──────────────────────────────────────────────────

    public func uiReset() { canvas.swiftEditorUiReset(handle) }

    public func uiBegin(
        kind: UIKind, id: Int32 = 0,
        flexGrow: Float = 0, flexShrink: Float = 1,
        width: Float = -1, height: Float = -1, padding: Float = 0
    ) {
        canvas.swiftEditorUiBegin(
            handle, kind.rawValue, id, flexGrow, flexShrink, width, height, padding
        )
    }

    public func uiText(
        id: Int32, text: String,
        r: Float, g: Float, b: Float, clickable: Bool
    ) {
        text.withCString {
            canvas.swiftEditorUiText(handle, id, $0, r, g, b, clickable)
        }
    }

    public func uiEnd() { canvas.swiftEditorUiEnd(handle) }
    public func uiCommit() { canvas.swiftEditorUiCommit(handle) }

    /// Drain click (and future) events. Returns widget id + kind (0=Click).
    public func uiPollEvent() -> (widgetId: Int32, kind: Int32)? {
        var id: Int32 = 0
        var kind: Int32 = 0
        let ok = canvas.swiftEditorUiPollEvent(handle, &id, &kind)
        return ok != 0 ? (id, kind) : nil
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
}
#endif
