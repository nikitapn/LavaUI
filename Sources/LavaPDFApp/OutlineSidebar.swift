import Foundation
import LavaPDFCore
import LavaUI

/// The table of contents down the left: one row per entry on show, indented
/// by depth, with a triangle on the ones that have children. The section you
/// are reading is lit, and its parents are kept open so it is always in view.
struct OutlineSidebar: View {
    @Bindable var session: ReaderSession

    static let width: Float = 280
    private static let indent: Float = 14

    var body: some View {
        let outline = session.outline
        return VStack(spacing: 0) {
            Text("Contents", color: Theme.current.textDim)
                .padding(10)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(session.visibleOutlineRows, id: \.self) { index in
                        row(index, item: outline.items[index], outline: outline)
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 6, bottom: 10, trailing: 6))
            }
            .flexGrow(1)
        }
        .frame(width: .pt(Self.width))
        .background(Theme.current.panel)
        .agentId("outline")
    }

    private func row(_ index: Int, item: Outline.Item, outline: Outline) -> some View {
        let current = index == session.currentSection
        let open = session.expanded.contains(index)
        // Indented by padding, not by a `Spacer` of a set width: a spacer
        // still grows, and a row of them split the free width and centred
        // every title.
        return HStack(alignment: .center, spacing: 2) {
            if outline.hasChildren(index) {
                Text(open ? "▾" : "▸", color: Theme.current.textDim,
                     onClick: { session.toggleExpanded(index) })
                    .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .frame(width: .pt(20))
                    .cursor(.pointer)
                    .agentId("outline-toggle-\(index)")
            } else {
                Text(" ").frame(width: .pt(20))
            }
            Text(item.title,
                 color: current ? Theme.current.textPrimary : Theme.current.textSecondary,
                 lineLimit: 1,
                 onClick: item.target == nil ? nil : { session.choose(outlineItem: index) })
                .padding(EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6))
                .flexGrow(1)
                .flexShrink(1)
                .cursor(item.target == nil ? nil : .pointer)
                .agentId("outline-\(index)")
        }
        .padding(EdgeInsets(top: 0, leading: Float(item.depth) * Self.indent, bottom: 0, trailing: 0))
        .background(current ? Theme.current.hover : Color(r: 0, g: 0, b: 0, a: 0))
        .cornerRadius(4)
        .scrollIntoView(when: current)
    }
}
