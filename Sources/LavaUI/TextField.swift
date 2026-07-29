#if canImport(CxxCanvas)
import Foundation

/// Single-line editable text.
///
/// Step 1 of the plan's Phase 7 ladder: Latin, no IME, no multi-line. The
/// editing logic itself is `TextEditingState` in `LavaText` (pure, tested
/// headlessly); this type is only the view/node plumbing around it.
///
/// The buffer lives on the *node*, not in `@State`, because a `PrimitiveView`
/// has no body and so never goes through `CompositeNode`'s state transplant.
/// The node persists across rebuilds, which is the same guarantee.
public struct TextField: PrimitiveView {
    @Binding public var text: String
    public var placeholder: String
    public var font: UIFont?
    public var onSubmit: (() -> Void)?
    /// When true, Enter inserts a newline instead of submitting, and the box
    /// grows to fit its lines. Hard line breaks only for now — soft wrap is a
    /// separate step, because a wrapped visual line is no longer a logical one
    /// and every index mapping has to account for that.
    public var isMultiline: Bool
    /// Height cap in lines when multi-line; the box grows up to this.
    public var maxLines: Int

    public init(
        text: Binding<String>,
        placeholder: String = "",
        font: UIFont? = nil,
        multiline: Bool = false,
        maxLines: Int = 8,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
        self.isMultiline = multiline
        self.maxLines = maxLines
        self.onSubmit = onSubmit
    }

    public var resolvedFont: UIFont? { font ?? FontStore.default }

    public var dumpDetail: String { "\"\(text)\"" }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .textField, label: "TextField", width: .auto, height: .auto)
        configure(leaf)
        leaf.editing = TextEditingState(text)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .textField else {
            return mountPrimitive()
        }
        // The binding is the source of truth for *content*; the node owns the
        // cursor. Only resync when the outside value actually diverged, or an
        // in-progress edit would have its caret reset on every frame.
        if leaf.editing.text != text {
            leaf.editing.setText(text, keepingCursor: true)
        }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        leaf.font = resolvedFont
        leaf.color = .primary
        leaf.placeholder = placeholder
        leaf.fillColor = Theme.current.inset
        leaf.cornerRadius = Theme.current.cornerRadius
        // Measure against the placeholder when empty so an empty field still
        // reserves a sensible line box.
        leaf.text = leaf.editing.text.isEmpty ? placeholder : leaf.editing.text
        leaf.minWidth = 80
        leaf.isMultiline = isMultiline
        leaf.maxLines = maxLines
        if isMultiline, let f = resolvedFont {
            // Hard-wrapped: height follows the line count directly.
            let shown = min(max(leaf.editing.lines.count, 1), maxLines)
            leaf.height = .pt(Float(shown) * f.lineHeight + Theme.current.controlPadding * 2)
        }

        let binding = _text
        let submit = onSubmit

        // Press: focus, place the caret, and start a drag session.
        leaf.onClickLocal = { [weak leaf] localX, localY, originX, originY in
            guard let leaf, let run = leaf.shapedRun() else { return }
            leaf.focusSelf(binding: binding, onSubmit: submit)

            let hit = leaf.index(atLocalX: localX, localY: localY) ?? run.index(atX: localX - LeafNode.textInset)
            let clicks = ClickCounter.register(x: originX + localX, y: originY + localY)

            if clicks >= 2 {
                // Double click selects the word; a third would select all, but
                // that is left out until it is asked for.
                leaf.editing.selectWord(at: hit)
            } else {
                leaf.editing.setCursor(hit)
                // Capture so the selection keeps extending once the pointer
                // leaves the field — otherwise the hit test simply misses.
                PointerCapture.capture(
                    leaf.id,
                    onMove: { [weak leaf] wx, wy in
                        guard let leaf, let run = leaf.shapedRun() else { return }
                        let lx = wx - originX
                        let ly = wy - originY
                        let target = leaf.index(atLocalX: lx, localY: ly)
                            ?? run.index(atX: lx - LeafNode.textInset)
                        leaf.editing.setCursor(target, extending: true)
                        CaretBlink.noteEdit()
                        ViewInvalidation.markDirty()
                    }
                )
            }
            CaretBlink.noteEdit()
            ViewInvalidation.markDirty()
        }
    }
}

extension LeafNode {
    /// Horizontal padding inside a field, matching the draw-side inset.
    static var textInset: Float { Theme.current.controlPadding }

    /// Shapes the current buffer for caret/selection maths. Cached on `UIFont`,
    /// so this is a dictionary hit on all but the first call per string.
    func shapedRun() -> ShapedRun? {
        guard let font = font ?? FontStore.default else { return nil }
        return font.shapedRun(editing.text)
    }

    /// Index under a point in node-local coordinates, resolving the line
    /// first. Nil when there is no font to shape with.
    func index(atLocalX x: Float, localY y: Float) -> String.Index? {
        guard let f = font ?? FontStore.default else { return nil }
        let inset = LeafNode.textInset
        let lineList = editing.lines
        let row = max(0, min(lineList.count - 1, Int((y - inset) / f.lineHeight)))
        let column = f.shapedRun(String(lineList[row])).index(atX: x - inset)
        let columnOffset = String(lineList[row]).distance(
            from: String(lineList[row]).startIndex, to: column
        )
        return editing.index(line: row, column: columnOffset)
    }

    func focusSelf(binding: Binding<String>, onSubmit: (() -> Void)?) {
        FocusManager.focus(
            id,
            onKey: { [weak self] event in
                guard let self else { return false }
                return self.handleKey(event, binding: binding, onSubmit: onSubmit)
            },
            onChar: { [weak self] character in
                guard let self else { return false }
                self.editing.insert(String(character))
                binding.wrappedValue = self.editing.text
                self.afterEdit()
                return true
            }
        )
    }

    private func afterEdit() {
        text = editing.text.isEmpty ? placeholder : editing.text
        markMeasureDirty()
        CaretBlink.noteEdit()
        ViewInvalidation.markDirty()
    }

    private func handleKey(
        _ event: KeyEvent, binding: Binding<String>, onSubmit: (() -> Void)?
    ) -> Bool {
        let shift = event.shift
        let before = editing.text

        switch event.key {
        case KeyCode.left:
            event.control ? editing.moveWordLeft(extending: shift)
                          : editing.moveLeft(extending: shift)
        case KeyCode.right:
            event.control ? editing.moveWordRight(extending: shift)
                          : editing.moveRight(extending: shift)
        case KeyCode.up:
            editing.moveUp(extending: shift)
        case KeyCode.down:
            editing.moveDown(extending: shift)
        case KeyCode.home:
            // Ctrl+Home is buffer start; bare Home is line start, which only
            // differ once there is more than one line.
            event.control ? editing.moveToStart(extending: shift)
                          : editing.moveToLineStart(extending: shift)
        case KeyCode.end:
            event.control ? editing.moveToEnd(extending: shift)
                          : editing.moveToLineEnd(extending: shift)
        case KeyCode.backspace:
            event.control ? editing.deleteWordBackward() : editing.deleteBackward()
        case KeyCode.delete:
            editing.deleteForward()
        case KeyCode.enter:
            if isMultiline, !event.control {
                editing.insert("\n")
            } else {
                onSubmit?()
            }
        case KeyCode.escape:
            FocusManager.resignFocus(id)
        case KeyCode.a where event.control:
            editing.selectAll()
        case KeyCode.z where event.control && event.shift:
            editing.redo()
        case KeyCode.z where event.control:
            editing.undo()
        // Ctrl+Y is the Windows-style redo; both are common enough to accept.
        case KeyCode.y where event.control:
            editing.redo()
        case KeyCode.c where event.control:
            if editing.hasSelection { ClipboardBridge.write(editing.selectedText) }
        case KeyCode.x where event.control:
            if editing.hasSelection {
                ClipboardBridge.write(editing.selectedText)
                editing.deleteBackward()
            }
        case KeyCode.v where event.control:
            let pasted = ClipboardBridge.read()
            if !pasted.isEmpty {
                // Single-line: a pasted newline would otherwise be invisible.
                editing.insert(pasted.replacingOccurrences(of: "\n", with: " "))
            }
        default:
            return false
        }

        if editing.text != before { binding.wrappedValue = editing.text }
        afterEdit()
        return true
    }
}

/// Indirection so `LavaUI` views can reach the clipboard without every view
/// carrying an `Editor` reference. The app installs this once at startup.
public enum ClipboardBridge {
    nonisolated(unsafe) public static var reader: (() -> String)?
    nonisolated(unsafe) public static var writer: ((String) -> Void)?

    static func read() -> String { reader?() ?? "" }
    static func write(_ text: String) { writer?(text) }
}

#endif
