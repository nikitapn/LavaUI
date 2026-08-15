import Foundation

/// One row of a `ComboBox`.
///
/// `tag` is both the identity and the value written back through the binding,
/// which is why it carries the `Identifiable` conformance rather than a
/// separate id: two rows with the same tag would be the same choice, and
/// `ForEach` would be right to complain about it.
public struct ComboBoxItem<Tag: Hashable>: Identifiable {
    public var tag: Tag
    public var title: String
    /// Dim trailing text — a path, a count, a kind. Drawn after the title and
    /// truncated first, so it never pushes the title out of the row.
    public var detail: String?

    public var id: Tag { tag }

    public init(_ title: String, tag: Tag, detail: String? = nil) {
        self.title = title
        self.tag = tag
        self.detail = detail
    }
}

/// A closed field showing the current choice, and a dropdown of the rest.
///
/// The list is an `overlay(alignment: .below)`, so it paints above everything,
/// escapes any surrounding clip, and takes input before the view underneath —
/// the three things a dropdown needs and a normal child cannot have. Clicking
/// away, or Escape, dismisses it through the same path menus use; nothing here
/// tracks that itself.
///
/// ```swift
/// @State private var tab = 0
/// ComboBox(
///     selection: $tab,
///     items: docs.enumerated().map {
///         ComboBoxItem($0.element.name, tag: $0.offset, detail: $0.element.path)
///     },
///     width: .pt(240)
/// )
/// ```
///
/// Mouse-driven only: there is no keyboard focus ring or arrow-key navigation
/// yet, because a composed view has no way to hold focus — that belongs to the
/// leaf nodes (`TextField`, `EditorView`) and would have to grow a focusable
/// container first.
public struct ComboBox<Tag: Hashable>: View {
    @Binding public var selection: Tag
    public var items: [ComboBoxItem<Tag>]
    /// Shown when nothing matches `selection` — an empty list, or a tag that
    /// was removed from under the binding.
    public var placeholder: String
    /// Width of the closed field. `.auto` sizes to the current title, which
    /// makes the field jump as the choice changes; a fixed width is usually
    /// what a switcher wants.
    public var width: Dimension
    /// Rows shown before the list starts scrolling.
    public var maxVisibleRows: Int

    @State private var isOpen = false

    public init(
        selection: Binding<Tag>,
        items: [ComboBoxItem<Tag>],
        placeholder: String = "—",
        width: Dimension = .auto,
        maxVisibleRows: Int = 10
    ) {
        self._selection = selection
        self.items = items
        self.placeholder = placeholder
        self.width = width
        self.maxVisibleRows = maxVisibleRows
    }

    public var body: some View {
        field.overlay(
            isPresented: $isOpen,
            alignment: .below,
            style: OverlayStyle(padding: 4, minWidth: menuMinWidth)
        ) {
            menu
        }
    }

    private var current: ComboBoxItem<Tag>? {
        items.first { $0.tag == selection }
    }

    private var field: some View {
        let theme = Environment.current.theme
        return HStack(
            width: width, padding: 0, alignment: .center, spacing: 8,
            onClick: { isOpen.toggle() }
        ) {
            Text(current?.title ?? placeholder,
                 color: current == nil ? .dim : .primary, lineLimit: 1)
            Spacer()
            // The same triangle a menu bar uses for a submenu, turned down.
            Text("▼", color: .muted)
        }
        .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 8))
        .background(theme.inset)
        .hoverBackground(theme.hover)
        .cornerRadius(theme.cornerRadius)
        .cursor(.pointer)
    }

    @ViewBuilder
    private var menu: some View {
        if items.count > maxVisibleRows {
            // A cap rather than a natural height: with fifty logs open the
            // list would otherwise be taller than the window, and the overlay
            // would clamp it to the viewport with no way to reach the bottom.
            ScrollView {
                rows
            }
            .frame(height: .pt(Float(maxVisibleRows) * rowHeight))
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .stretch, spacing: 1) {
            ForEach(items) { item in
                row(item)
            }
        }
    }

    private func row(_ item: ComboBoxItem<Tag>) -> some View {
        let theme = Environment.current.theme
        let selected = item.tag == selection
        return HStack(
            padding: 0, alignment: .center, spacing: 8,
            onClick: { choose(item.tag) }
        ) {
            // A fixed marker column, present on every row, so titles line up
            // and the list does not shift by a glyph as the choice moves.
            Text(selected ? "✓" : " ", color: .accent)
            Text(item.title, color: selected ? .accent : .primary, lineLimit: 1)
            if let detail = item.detail {
                Spacer()
                Text(detail, color: .dim, lineLimit: 1)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .background(selected ? theme.hover : .clear)
        .hoverBackground(theme.hover)
        .cornerRadius(4)
        .cursor(.pointer)
    }

    private func choose(_ tag: Tag) {
        isOpen = false
        // Not written back when it did not change: a switcher's binding is
        // usually a setter with side effects (save the outgoing scroll offset,
        // read the incoming file), and re-picking the current row should not
        // set any of that going.
        guard tag != selection else { return }
        selection = tag
    }

    /// Keeps the open list at least as wide as the field it drops out of. A
    /// narrower menu under a wide field reads as a different control.
    private var menuMinWidth: Float {
        if case let .point(w) = width { return w }
        return 0
    }

    private var rowHeight: Float {
        (Environment.current.font?.lineHeight ?? 18) + 9
    }
}
