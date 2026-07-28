import FBDModel
import Foundation
import LavaUI

/// App chrome: project tree + diagram host + properties (uses `LavaUI` views).
public struct EditorChrome: View {
    public var blocks: [Block]
    /// Optional decorative icon (e.g. loaded football PNG) in the project panel.
    public var brandImage: UIImage?

    /// Owned here, not by the app. The struct is rebuilt every frame; the
    /// storage behind these survives via StateTransfer, so the run loop no
    /// longer has to track selection/clicks and diff them by hand.
    @State private var selectedId: String?
    @State private var clickCount: Int = 0
    @State private var filter: String = ""

    public init(blocks: [Block], brandImage: UIImage? = nil) {
        self.blocks = blocks
        self.brandImage = brandImage
    }

    /// Blocks matching the filter field (case-insensitive substring).
    private var visibleBlocks: [Block] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return blocks }
        return blocks.filter { $0.name.lowercased().contains(needle) }
    }

    public var body: some View {
        let sel = selectedId ?? blocks.first.map { String($0.id.rawValue) }

        // Root fills the window via LayoutHost (exact width/height). flexGrow
        // on the row is a no-op as yoga root but documents intent; DiagramHost
        // takes remaining main-axis space, columns stretch on the cross axis.
        return HStack(flexGrow: 1, padding: 4) {
            VStack(flexGrow: 0, width: .pt(220), height: .auto, padding: 8) {
                if let brandImage {
                    Image(brandImage, width: .pt(48), height: .pt(48), contentMode: .fit)
                }
                Text("Project", color: .accent)
                TextField(text: $filter, placeholder: "filter…")
                Text("Diagrams", color: .secondary)
                Text("  Main", color: .primary)
                ForEach(visibleBlocks, id: \.id) { b in
                    let id = String(b.id.rawValue)
                    let selected = (id == sel)
                    let name = b.name
                    Text(
                        "  \(name)",
                        color: selected ? .selected : .primary,
                        onClick: {
                            selectedId = id
                            clickCount += 1
                        }
                    )
                }
                Spacer()
                Text("clicks: \(clickCount)", color: .muted)
            }

            DiagramHost(flexGrow: 1)

            VStack(flexGrow: 0, width: .pt(260), height: .auto, padding: 8) {
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
                    // Phase 4: wrap inside fixed-width panel (Yoga AtMost measure).
                    Text(
                        "Help: This paragraph is measured with Font::measure "
                            + "and wraps to the panel width. Hit-test boxes "
                            + "match glyph metrics.",
                        color: .secondary
                    )
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

        // Resize reflow: same retained tree, larger viewport → DiagramHost grows.
        let mid1 = frames.first(where: { $0.label == "DiagramHost" })?.w ?? 0
        let wideW = width + 400
        let wideH = height + 200
        _ = host.calculateLayout(width: wideW, height: wideH)
        let mid2 = host.lastFrames.first(where: { $0.label == "DiagramHost" })?.w ?? 0
        let root2 = host.lastFrames.first(where: { $0.label == "HStack" })
        if abs((root2?.w ?? 0) - wideW) > 2 || abs((root2?.h ?? 0) - wideH) > 2 {
            let msg =
                "Phase2Dump: root did not fill resized viewport "
                + "(\(Int(root2?.w ?? 0))×\(Int(root2?.h ?? 0)) vs \(Int(wideW))×\(Int(wideH)))\n"
            FileHandle.standardError.write(Data(msg.utf8))
            ok = false
        }
        if mid2 <= mid1 + 50 {
            let msg =
                "Phase2Dump: DiagramHost did not grow on resize "
                + "(\(Int(mid1)) → \(Int(mid2)))\n"
            FileHandle.standardError.write(Data(msg.utf8))
            ok = false
        } else {
            let msg =
                "Phase2Dump: resize reflow DiagramHost \(Int(mid1)) → \(Int(mid2))\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        FileHandle.standardError.write(
            Data(ok ? "Phase2Dump: PASS\n".utf8 : "Phase2Dump: FAIL\n".utf8)
        )
    }
}

enum Phase4TextDump {
    /// Font measure + cache: direct re-measure hits cache; tree shows multi-line wrap.
    static func run(chrome: some View, width: Float, height: Float) {
        guard let font = FontStore.default else {
            FileHandle.standardError.write(Data("Phase4Dump: FAIL (no default UIFont)\n".utf8))
            return
        }

        let cache = TextLayoutCache.shared
        cache.clear()

        // Direct cache exercise (Yoga won't remeasure clean leaves).
        let sample =
            "Help: This paragraph is measured with Font::measure "
            + "and wraps to the panel width. Hit-test boxes "
            + "match glyph metrics."
        let panelInner: Float = 260 - 16 // VStack width minus padding
        _ = cache.layout(font: font, text: sample, availWidth: panelInner, mode: 2)
        _ = cache.layout(font: font, text: sample, availWidth: panelInner, mode: 2)
        _ = cache.layout(font: font, text: sample, availWidth: panelInner, mode: 2)
        _ = cache.layout(font: font, text: sample, availWidth: panelInner, mode: 1)

        // Tree layout warms the cache (misses expected).
        let host = LayoutHost()
        host.setRoot(chrome)
        _ = host.calculateLayout(width: width, height: height)

        // Static remesure thrash — count only these for the hit-rate gate.
        cache.resetStats()
        for _ in 0..<5 {
            host.invalidateTextMetrics()
            _ = host.calculateLayout(width: width, height: height)
        }

        let rate = cache.hitRate
        FileHandle.standardError.write(
            Data(
                String(
                    format: "Phase4 cache (static remesure): hits=%d misses=%d rate=%.1f%%\n",
                    cache.hits, cache.misses, rate * 100
                ).utf8
            )
        )

        let entry = cache.layout(font: font, text: sample, availWidth: panelInner, mode: 2)
        FileHandle.standardError.write(
            Data(
                "Phase4 wrap: lines=\(entry.lines.count) size=\(entry.width)×\(entry.height)\n"
                    .utf8
            )
        )

        let frames = host.lastFrames
        let multiLineFrame = frames.contains { f in
            f.label.hasPrefix("Text") && f.h > font.lineHeight * 1.8
        }

        var ok = true
        // After warmup + remesure thrash, hits should dominate (plan: >90% static).
        if rate < 0.9 {
            FileHandle.standardError.write(
                Data("Phase4Dump: expected cache hit rate >= 90% on static remesure\n".utf8)
            )
            ok = false
        }
        if entry.lines.count < 2 {
            FileHandle.standardError.write(
                Data("Phase4Dump: expected wrapped paragraph (>=2 lines)\n".utf8)
            )
            ok = false
        }
        if !multiLineFrame {
            FileHandle.standardError.write(
                Data("Phase4Dump: expected multi-line Text frame in tree layout\n".utf8)
            )
            ok = false
        }
        FileHandle.standardError.write(
            Data(ok ? "Phase4Dump: PASS\n".utf8 : "Phase4Dump: FAIL\n".utf8)
        )
    }
}

/// Phase 5 self-check, through public API only: storage must survive the view
/// struct being rebuilt, and mutating it must invalidate.
enum Phase5StateDump {
    /// Reports its current state and hands back a mutator each time `body`
    /// runs. A side-effecting body is fine for a probe and keeps the check
    /// from needing access to LavaUI internals.
    struct Probe: View {
        @State var count = 0
        var report: (Int, @escaping () -> Void) -> Void

        var body: some View {
            report(count, { count += 1 })
            return Text("count: \(count)")
        }
    }

    static func run() {
        var ok = true
        func require(_ cond: Bool, _ what: String) {
            if !cond {
                FileHandle.standardError.write(Data("Phase5: FAIL \(what)\n".utf8))
                ok = false
            }
        }

        var seen = 0
        var mutate: () -> Void = {}
        let probe = Probe { value, bump in
            seen = value
            mutate = bump
        }

        let host = LayoutHost()
        host.setRoot(probe)
        require(seen == 0, "initial state (got \(seen))")

        _ = ViewInvalidation.consume()   // clear the mount-time flag
        mutate()
        require(ViewInvalidation.isDirty, "mutation did not invalidate")

        // Parent rebuild: a brand-new struct with brand-new @State storage,
        // which must be replaced by the storage the node already owned.
        host.setRoot(Probe { value, bump in
            seen = value
            mutate = bump
        })
        require(seen == 1, "state lost across rebuild (got \(seen))")

        FileHandle.standardError.write(Data(ok ? "Phase5: PASS\n".utf8 : "Phase5: FAIL\n".utf8))
    }
}
