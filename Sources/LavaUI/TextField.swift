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

    public init(
        text: Binding<String>,
        placeholder: String = "",
        font: UIFont? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
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
        leaf.fillColor = Color(r: 0.10, g: 0.11, b: 0.14)
        // Measure against the placeholder when empty so an empty field still
        // reserves a sensible line box.
        leaf.text = leaf.editing.text.isEmpty ? placeholder : leaf.editing.text
        leaf.minWidth = 80

        let binding = _text
        let submit = onSubmit

        // Click: focus, and place the caret where the pointer landed.
        leaf.onClickLocal = { [weak leaf] localX, _ in
            guard let leaf else { return }
            leaf.focusSelf(binding: binding, onSubmit: submit)
            if let run = leaf.shapedRun() {
                leaf.editing.setCursor(run.index(atX: localX - LeafNode.textInset))
            }
            CaretBlink.noteEdit()
            ViewInvalidation.markDirty()
        }
    }
}

extension LeafNode {
    /// Horizontal padding inside a field, matching the draw-side inset.
    static let textInset: Float = 4

    /// Shapes the current buffer for caret/selection maths. Cached on `UIFont`,
    /// so this is a dictionary hit on all but the first call per string.
    func shapedRun() -> ShapedRun? {
        guard let font = font ?? FontStore.default else { return nil }
        return font.shapedRun(editing.text)
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
        case KeyCode.home:
            editing.moveToStart(extending: shift)
        case KeyCode.end:
            editing.moveToEnd(extending: shift)
        case KeyCode.backspace:
            event.control ? editing.deleteWordBackward() : editing.deleteBackward()
        case KeyCode.delete:
            editing.deleteForward()
        case KeyCode.enter:
            onSubmit?()
        case KeyCode.escape:
            FocusManager.resignFocus(id)
        case KeyCode.a where event.control:
            editing.selectAll()
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
