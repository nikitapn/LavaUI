import FBDModel
import Foundation

/// Chrome description as a composite `View`.
/// Live window still uses legacy `UI` commit until Phase 3 cutover.
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
            VStack(width: .pt(220), padding: 8) {
                Text("Project", color: .accent)
                Text("Diagrams", color: .secondary)
                Text("  Main", color: .primary)
                ForEach(blocks, id: \.id) { b in
                    let id = String(b.id.rawValue)
                    let selected = (id == sel)
                    let name = b.name
                    Text(
                        "  \(name)",
                        color: selected ? .selected : .primary,
                        onClick: { onSelect(id, name) }
                    )
                }
                Spacer()
                Text("clicks: \(clickCount)", color: .muted)
            }

            DiagramHost()

            VStack(width: .pt(260), padding: 8) {
                Text("Properties", color: .accent)
                if let sel, let bid = Int(sel),
                   let block = blocks.first(where: { $0.id.rawValue == bid })
                {
                    Text("Name: \(block.name)")
                    Text("Kind: \(block.kind.displayName)")
                    Text("In: \(block.inputs.count)  Out: \(block.outputs.count)")
                    ForEach(
                        block.properties.sorted(by: { $0.key < $1.key }).map {
                            PropKV(key: $0.key, value: $0.value.description)
                        },
                        id: \.key
                    ) { row in
                        Text("\(row.key): \(row.value)", color: Color(r: 0.75, g: 0.75, b: 0.75))
                    }
                } else {
                    Text("(nothing selected)", color: .secondary)
                }
                Spacer()
                Text("Hot-update: re-commit tree", color: .dim)
            }
        }
    }
}

struct PropKV: Hashable {
    var key: String
    var value: String
}

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
                    Data("Phase1Dump: expected \(needle)\n".utf8)
                )
                ok = false
            }
        }
        require("EditorChrome")
        require("TupleView")
        require("EitherView")
        require("ForEach")
        require("HStack")
        FileHandle.standardError.write(
            Data(ok ? "Phase1Dump: PASS\n".utf8 : "Phase1Dump: FAIL\n".utf8)
        )
    }
}

enum Phase2LayoutDump {
    /// Exercises retained recon: mount once, setRoot again, root id must match.
    static func run(chrome: some View, width: Float = 1280, height: Float = 800) {
        let host = LayoutHost()
        host.setRoot(chrome)
        let id1 = host.rootID

        // Second commit — must reconcile, not remount root.
        host.setRoot(chrome)
        let id2 = host.rootID

        // dumpFrames lays out once and caches; re-read committed frames.
        host.dumpFrames(width: width, height: height)
        let frames = host.lastFrames

        var ok = true
        if id1 == nil || id1 != id2 {
            FileHandle.standardError.write(
                Data(
                    "Phase2Dump: root identity not retained (id1=\(String(describing: id1)) id2=\(String(describing: id2)))\n"
                        .utf8
                )
            )
            ok = false
        }
        if host.mountCount != 1 {
            FileHandle.standardError.write(
                Data("Phase2Dump: expected mountCount=1 got \(host.mountCount)\n".utf8)
            )
            ok = false
        }
        if host.reconcileCount < 1 {
            FileHandle.standardError.write(
                Data("Phase2Dump: expected reconcileCount>=1 got \(host.reconcileCount)\n".utf8)
            )
            ok = false
        }
        // Fragments must not appear as layout boxes.
        if frames.contains(where: {
            $0.label.hasPrefix("ForEach") || $0.label.hasPrefix("EitherView")
                || $0.label.hasPrefix("TupleView") || $0.label.hasPrefix("OptionalView")
        }) {
            FileHandle.standardError.write(
                Data("Phase2Dump: fragment leaked into layout frames\n".utf8)
            )
            ok = false
        }
        if !frames.contains(where: { $0.label == "DiagramHost" && $0.w > 100 && $0.h > 100 }) {
            FileHandle.standardError.write(
                Data("Phase2Dump: expected flex DiagramHost\n".utf8)
            )
            ok = false
        }
        if !frames.contains(where: { $0.label == "VStack" && abs($0.w - 220) < 1 }) {
            FileHandle.standardError.write(
                Data("Phase2Dump: expected 220pt left VStack\n".utf8)
            )
            ok = false
        }
        FileHandle.standardError.write(
            Data(ok ? "Phase2Dump: PASS\n".utf8 : "Phase2Dump: FAIL\n".utf8)
        )
    }
}
