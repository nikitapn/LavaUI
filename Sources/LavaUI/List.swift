import Foundation

/// A scrolling column of rows, one of which is selected.
///
/// What every sidebar and result list in the apps was building by hand: rows
/// in a `ScrollView`, a fill on the selected row and a hover on the rest, a
/// click that selects and a double click that opens, and the arrows, Home,
/// End and Page Up/Down moving the selection with the view following it. The
/// row's contents are the caller's; the row's chrome — fill, rounding, insets,
/// the click target — is the list's, so every list on the desktop selects the
/// same way.
///
/// ```swift
/// @State private var section: Section? = .appearance
/// List(Section.allCases, id: \.self, selection: $section,
///      onActivate: { open($0) }) { section, selected in
///     Text(section.title, color: selected ? .primary : .secondary)
/// }
/// ```
///
/// The keyboard is the list's once it has been pressed (`.focusable`), and
/// stays until something else takes it. Keys it does not use — anything but
/// the arrows, Home, End, Page Up/Down and Enter — fall through to the
/// window's shortcuts.
///
/// **Two ways to lay rows out**, chosen by `rowHeight`. Without one, every
/// row is mounted and takes its natural height, which is what a sidebar of
/// a dozen rows whose subtitles wrap wants. With one, rows are that height
/// and only those on screen are mounted (`LazyVStack`), which is what a list
/// of ten thousand files wants — and what turns a selection a thousand rows
/// away into one scroll.
///
/// **Results under a search field** — a launcher, a file search — want the
/// other behaviour throughout, and `ListBehavior.results` is that: the
/// pointer selects what it is over, one click opens, and the list never takes
/// the keyboard, because the field above it keeps it and moves the selection
/// itself.
///
/// Single selection only; a file list's Ctrl and Shift ranges are still the
/// explorer's own.
public struct List<Data: RandomAccessCollection, ID: Hashable, Row: View>: View
where Data.Index == Int {
    /// The elements, one row each, in order.
    public var data: Data
    /// What identifies an element. The selection holds one of these, so the
    /// selected row stays selected when the data is reordered or filtered.
    public var id: KeyPath<Data.Element, ID>
    /// The selected element's id, or nil for none. Clicking a row, or moving
    /// with the keyboard, writes here.
    @Binding public var selection: ID?
    /// Height of every row, in points — and with it, lazy mounting. Nil lays
    /// every row out at its natural height. See the type's notes.
    public var rowHeight: Float?
    /// Space between rows, in points.
    public var spacing: Float
    /// Space around the rows, inside the scrolling area.
    public var padding: Float
    /// Space between a row's edge — its fill — and its contents.
    public var rowInsets: EdgeInsets
    /// How the pointer and the keyboard work it. See `ListBehavior`.
    public var behavior: ListBehavior
    /// The selected row's fill, or nil for the theme's `selectionFill`.
    public var selectionFill: Color?
    /// Rows' corner radius, or nil for the theme's.
    public var cornerRadius: Float?
    /// How far the scroll indicator sits in from the right edge.
    public var indicatorInset: Float
    /// Double click, or Enter, on a row. Nil makes both do nothing beyond
    /// selecting.
    public var onActivate: ((Data.Element) -> Void)?
    /// Builds one row's contents; the second argument is whether it is the
    /// selected row.
    public var row: (Data.Element, Bool) -> Row

    /// Heights the keyboard needs, for Page Up/Down. Kept in a reference
    /// rather than `@State` because layout writes them on every pass, and a
    /// write to state is a redraw.
    @State private var metrics = ListMetrics()

    /// Creates a list. Every parameter matches the property of the same name.
    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        selection: Binding<ID?>,
        rowHeight: Float? = nil,
        spacing: Float = 2,
        padding: Float = 0,
        rowInsets: EdgeInsets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10),
        behavior: ListBehavior = .standard,
        selectionFill: Color? = nil,
        cornerRadius: Float? = nil,
        indicatorInset: Float = 0,
        onActivate: ((Data.Element) -> Void)? = nil,
        @ViewBuilder row: @escaping (Data.Element, Bool) -> Row
    ) {
        self.data = data
        self.id = id
        self._selection = selection
        self.rowHeight = rowHeight
        self.spacing = spacing
        self.padding = padding
        self.rowInsets = rowInsets
        self.behavior = behavior
        self.selectionFill = selectionFill
        self.cornerRadius = cornerRadius
        self.indicatorInset = indicatorInset
        self.onActivate = onActivate
        self.row = row
    }

    /// A list whose selection is never empty — a sidebar that always shows
    /// some page. Moving off a row writes the new one; nothing writes nil.
    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        selection: Binding<ID>,
        rowHeight: Float? = nil,
        spacing: Float = 2,
        padding: Float = 0,
        rowInsets: EdgeInsets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10),
        behavior: ListBehavior = .standard,
        selectionFill: Color? = nil,
        cornerRadius: Float? = nil,
        indicatorInset: Float = 0,
        onActivate: ((Data.Element) -> Void)? = nil,
        @ViewBuilder row: @escaping (Data.Element, Bool) -> Row
    ) {
        self.init(
            data, id: id,
            selection: Binding<ID?>(
                get: { selection.wrappedValue },
                set: { if let new = $0 { selection.wrappedValue = new } }
            ),
            rowHeight: rowHeight, spacing: spacing, padding: padding,
            rowInsets: rowInsets, behavior: behavior, selectionFill: selectionFill,
            cornerRadius: cornerRadius, indicatorInset: indicatorInset,
            onActivate: onActivate, row: row
        )
    }

    public var body: some View {
        let behavior = behavior
        return ScrollView(indicatorInset: indicatorInset, revealInset: padding) {
            if let rowHeight {
                VStack(padding: padding, spacing: 0) {
                    LazyVStack(
                        data, rowHeight: rowHeight, spacing: spacing,
                        scrollTarget: selectedIndex
                    ) { element in
                        cell(element)
                    }
                }
            } else {
                VStack(padding: padding, spacing: spacing) {
                    ForEach(data, id: id) { element in
                        cell(element)
                            .scrollIntoView(when: isSelected(element))
                            .onFrame { [metrics] frame in metrics.row = frame.h }
                    }
                }
            }
        }
        .onFrame { [metrics] frame in metrics.viewport = frame.h }
        // Always applied, and switched off by `enabled`: whether a modifier
        // is there must not change with a setting, or changing the setting
        // would remount the list.
        .focusable(enabled: behavior.takesFocus, onKey: handleKey)
    }

    private func isSelected(_ element: Data.Element) -> Bool {
        selection == element[keyPath: id]
    }

    private func cell(_ element: Data.Element) -> some View {
        let theme = Environment.current.theme
        let selected = isSelected(element)
        let fill = selectionFill ?? theme.selectionFill
        let hovers = behavior.selectsOnHover
        let id = element[keyPath: self.id]
        return HStack(
            height: rowHeight.map { .pt($0) } ?? .auto, alignment: .center,
            onPointer: { _, button in press(element, button: button) },
            onHover: hovers ? { inside in if inside { select(id) } } : nil
        ) {
            row(element, selected)
        }
        .padding(rowInsets)
        // `selectionFill`, not `selected`: the latter is the bright highlight
        // a menu draws behind *dark* text, and a row's own text on it is
        // unreadable — Settings' sidebar found that out first.
        .background(selected ? fill : .clear)
        // The selected row keeps its fill under the pointer: a hover tint
        // over it would read as the selection moving. Where the pointer
        // selects, the row under it is about to be the selected one, and
        // the renderer's tint gets there a frame before the client does.
        .hoverBackground(selected || hovers ? fill : theme.hover)
        .cornerRadius(cornerRadius ?? theme.cornerRadius)
    }

    private func press(_ element: Data.Element, button: Int32) {
        guard button == PointerButton.left else { return }
        let p = PointerState.window
        let clicks = ClickCounter.register(x: p.x, y: p.y)
        select(element[keyPath: id])
        if clicks == behavior.clicksToActivate { onActivate?(element) }
    }

    /// Written only when it changes, for the same reason `ComboBox` does: a
    /// selection's setter is often a page load.
    private func select(_ new: ID) {
        guard selection != new else { return }
        selection = new
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return data.firstIndex { $0[keyPath: id] == selection }
    }

    /// Rows a Page Up/Down moves: a viewport's worth less one, so the row
    /// that was at the edge is still on screen after it.
    private var pageRows: Int {
        let row = (rowHeight ?? metrics.row) + spacing
        guard row > 0 else { return 1 }
        return max(1, Int(metrics.viewport / row) - 1)
    }

    private func handleKey(_ event: KeyEvent) -> Bool {
        guard !data.isEmpty else { return false }
        let last = data.count - 1
        let current = selectedIndex
        let target: Int
        switch event.key {
        case KeyCode.up:
            target = current.map { $0 - 1 } ?? last
        case KeyCode.down:
            target = current.map { $0 + 1 } ?? 0
        case KeyCode.home:
            target = 0
        case KeyCode.end:
            target = last
        case KeyCode.pageUp:
            target = (current ?? 0) - pageRows
        case KeyCode.pageDown:
            target = (current ?? 0) + pageRows
        case KeyCode.enter:
            guard let current else { return false }
            onActivate?(data[current])
            return true
        default:
            return false
        }
        select(data[min(max(target, 0), last)][keyPath: id])
        return true
    }
}

extension List where Data.Element: Identifiable, ID == Data.Element.ID {
    /// A list of `Identifiable` elements, selected by `id`.
    public init(
        _ data: Data,
        selection: Binding<ID?>,
        rowHeight: Float? = nil,
        spacing: Float = 2,
        padding: Float = 0,
        rowInsets: EdgeInsets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10),
        behavior: ListBehavior = .standard,
        selectionFill: Color? = nil,
        cornerRadius: Float? = nil,
        indicatorInset: Float = 0,
        onActivate: ((Data.Element) -> Void)? = nil,
        @ViewBuilder row: @escaping (Data.Element, Bool) -> Row
    ) {
        self.init(
            data, id: \.id, selection: selection, rowHeight: rowHeight,
            spacing: spacing, padding: padding, rowInsets: rowInsets,
            behavior: behavior, selectionFill: selectionFill,
            cornerRadius: cornerRadius, indicatorInset: indicatorInset,
            onActivate: onActivate, row: row
        )
    }
}

/// See `List.metrics`.
final class ListMetrics {
    /// The scrolling area's height.
    var viewport: Float = 0
    /// A row's height, when rows take their natural one — the last laid out,
    /// which for Page Up/Down is close enough.
    var row: Float = 0
}

/// How a `List` answers the pointer and the keyboard.
public struct ListBehavior: Sendable, Equatable {
    /// Selection follows the pointer, as in a launcher's results.
    public var selectsOnHover: Bool
    /// Clicks on a row that call `onActivate`: 2 for a double click, 1 for a
    /// row that opens on a click.
    public var clicksToActivate: Int
    /// Whether a press gives the list the keyboard. Off where something else
    /// — a search field — holds it and moves the selection itself.
    public var takesFocus: Bool

    /// Creates a behaviour. Every parameter matches the property of the same name.
    public init(selectsOnHover: Bool, clicksToActivate: Int, takesFocus: Bool) {
        self.selectsOnHover = selectsOnHover
        self.clicksToActivate = clicksToActivate
        self.takesFocus = takesFocus
    }

    /// A sidebar or a file list: a click selects, a double click or Enter
    /// opens, and the arrows are the list's once it has been pressed.
    public static let standard = ListBehavior(
        selectsOnHover: false, clicksToActivate: 2, takesFocus: true
    )

    /// Results under a search field: the pointer selects, a click opens, and
    /// the field keeps the keyboard.
    public static let results = ListBehavior(
        selectsOnHover: true, clicksToActivate: 1, takesFocus: false
    )
}
