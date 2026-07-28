import FBDModel
import Foundation

/// Phase 1 rewrite of `rebuildChrome()` as a composite `View`.
/// Description only — still rendered via the legacy `UI`/`UINode` path until
/// later phases wire nodes + draw list.
public struct EditorChrome: View {
    public var blocks: [Block]
    public var selectedId: String?
    public var clickCount: Int
    public var onSelect: (String, String) -> Void

    public init(
        blocks: [Block],
        selectedId: String?,
        clickCount: Int,
        onSelect: @escaping (String, String) -> Void
    ) {
        self.blocks = blocks
        self.selectedId = selectedId
        self.clickCount = clickCount
        self.onSelect = onSelect
    }

    public var body: some View {
        let sel = selectedId ?? blocks.first.map { String($0.id.rawValue) }

        return HStack(flexGrow: 1, padding: 4) {
            VStack(width: 220, padding: 8) {
                Text("Project", r: 0.7, g: 0.75, b: 0.9)
                Text("Diagrams", r: 0.55, g: 0.55, b: 0.6)
                Text("  Main", r: 0.85, g: 0.85, b: 0.85)
                for b in blocks {
                    let id = String(b.id.rawValue)
                    let selected = (id == sel)
                    let name = b.name
                    Text(
                        "  \(name)",
                        r: selected ? 1.0 : 0.8,
                        g: selected ? 0.85 : 0.8,
                        b: selected ? 0.4 : 0.8,
                        onClick: { onSelect(id, name) }
                    )
                }
                Spacer()
                Text("clicks: \(clickCount)", r: 0.5, g: 0.6, b: 0.5)
            }

            DiagramHost()

            VStack(width: 260, padding: 8) {
                Text("Properties", r: 0.7, g: 0.75, b: 0.9)
                if let sel, let bid = Int(sel),
                   let block = blocks.first(where: { $0.id.rawValue == bid })
                {
                    Text("Name: \(block.name)")
                    Text("Kind: \(block.kind.displayName)")
                    Text("In: \(block.inputs.count)  Out: \(block.outputs.count)")
                    for (k, v) in block.properties.sorted(by: { $0.key < $1.key }) {
                        Text("\(k): \(v.description)", r: 0.75, g: 0.75, b: 0.75)
                    }
                } else {
                    Text("(nothing selected)", r: 0.5, g: 0.5, b: 0.5)
                }
                Spacer()
                Text("Hot-update: re-commit tree", r: 0.45, g: 0.55, b: 0.5)
            }
        }
    }
}

/// Type-structure self-check (Phase 1 done criterion).
enum Phase1Dump {
    static func run(chrome: some View) {
        let lines = chrome.structureLines()
        FileHandle.standardError.write(Data("--- Phase 1 View dump ---\n".utf8))
        for line in lines {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        FileHandle.standardError.write(Data("--- end dump ---\n".utf8))

        let joined = lines.joined(separator: "\n")
        var ok = true
        func require(_ needle: String) {
            if !joined.contains(needle) {
                FileHandle.standardError.write(
                    Data("Phase1Dump: expected \(needle) in type tree\n".utf8)
                )
                ok = false
            }
        }
        require("EditorChrome")
        require("TupleView")
        require("EitherView")
        require("ArrayView")
        require("HStack")
        require("VStack")
        require("DiagramHost")
        FileHandle.standardError.write(
            Data(ok ? "Phase1Dump: PASS\n".utf8 : "Phase1Dump: FAIL\n".utf8)
        )
    }
}
