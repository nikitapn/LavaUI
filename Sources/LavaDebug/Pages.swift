#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI

// The five pages. Every one of them is a table, and the shared pieces below —
// `Row`, `Bar`, `Card` — are what keep the five looking like one window.

/// A proportional bar. The only chart here, because every quantity in this
/// report is "a part of a total" and a bar answers that faster than a number.
struct Bar: View {
    let fraction: Double
    let color: Color
    var width: Float = 180

    var body: some View {
        let filled = max(0, min(1, fraction))
        return HStack(width: .pt(width), height: .pt(8), spacing: 0) {
            HStack(width: .pt(width * Float(filled)), height: .pt(8), spacing: 0) {}
                .background(color)
                .cornerRadius(4)
            Spacer()
        }
        .background(Theme.current.inset)
        .cornerRadius(4)
    }
}

/// A titled block, so a page reads as sections rather than as one long list.
struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title, color: Theme.current.textSecondary)
            VStack(padding: 12, spacing: 6) { content }
                .background(Theme.current.panel)
                .cornerRadius(10)
        }
    }
}

/// One label/value line.
struct Row: View {
    let label: String
    let value: String
    var detail: String = ""
    var emphasis: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label, color: emphasis ? Theme.current.textPrimary
                                        : Theme.current.textSecondary)
            Spacer()
            if !detail.isEmpty {
                Text(detail, color: Theme.current.textDim)
            }
            Text(value, color: Theme.current.textPrimary)
        }
    }
}

// MARK: - Overview

/// The numbers that answer "how much, and is that a lot".
///
/// Three totals rather than one, because they disagree and the disagreement is
/// the information: the driver's figure includes everything the process touched,
/// VMA's is what the allocator holds, and the ledger's is what has an owner. A
/// gap between the last two is memory nothing in canvas asked for — the
/// swapchain, the driver's own working set — and knowing that stops a search for
/// a leak that is not there.
struct OverviewPage: View {
    let store: GpuStore
    let small: UIFont

    var body: some View {
        let report = store.report
        return ScrollView {
            VStack(spacing: 16) {
                Card("Device") {
                    Row(label: report.deviceName.isEmpty ? "no GPU device"
                                                         : report.deviceName,
                        value: "", emphasis: true)
                    Row(label: "MSAA samples",
                        value: "\(report.samples)x",
                        detail: report.samples == report.maxSamples
                            ? "the most this device allows"
                            : "device allows \(report.maxSamples)x")
                }

                Card("Totals") {
                    Row(label: "Driver attributes to this process",
                        value: humanBytes(report.heapUsageBytes),
                        detail: "of \(humanBytes(report.heapBudgetBytes)) budget",
                        emphasis: true)
                    Bar(fraction: fraction(report.heapUsageBytes,
                                           report.heapBudgetBytes),
                        color: Theme.current.accent, width: 420)
                    Row(label: "Allocator holds",
                        value: humanBytes(report.vmaBlockBytes),
                        detail: "\(humanBytes(report.vmaAllocatedBytes)) handed out")
                    Row(label: "Accounted for below",
                        value: humanBytes(report.ownBytes),
                        detail: "\(report.allocations.count) allocation(s)")
                    if report.retiringBytes > 0 {
                        Row(label: "Freed, waiting for frames to retire",
                            value: humanBytes(report.retiringBytes))
                    }
                    if report.foreignBytes > 0 {
                        Row(label: "Client buffers mapped in (not ours)",
                            value: humanBytes(report.foreignBytes))
                    }
                }

                Card("By category") {
                    ForEach(categories, id: \.name) { entry in
                        VStack(spacing: 4) {
                            Row(label: entry.name,
                                value: humanBytes(entry.bytes),
                                detail: "\(percent(entry.bytes, of: report.ownBytes))%")
                            Bar(fraction: fraction(entry.bytes, report.ownBytes),
                                color: color(for: entry.name), width: 420)
                        }
                    }
                }
            }
            .font(small)
        }
    }

    /// Summed from the allocation list rather than sent as its own table: one
    /// source of truth means a category total can never contradict the rows
    /// under it.
    private var categories: [(name: String, bytes: UInt64)] {
        var totals: [String: UInt64] = [:]
        for alloc in store.report.allocations where !alloc.foreign {
            totals[alloc.category, default: 0] += alloc.bytes
        }
        return totals.map { (name: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    private func fraction(_ part: UInt64, _ whole: UInt64) -> Double {
        whole == 0 ? 0 : Double(part) / Double(whole)
    }

    /// Render targets in the accent colour, caches in the muted one. The point
    /// is not decoration: it separates "what the desktop must have to draw" from
    /// "what it is keeping in case it needs it again", which are the two halves
    /// of any decision about this report.
    private func color(for category: String) -> Color {
        category.hasPrefix("window") || category == "blur scratch"
            ? Theme.current.accent
            : Theme.current.textMuted
    }
}

// MARK: - Windows

/// What each canvas window costs.
///
/// The important column is the size, and the important fact is that one window
/// on screen is several of these. A decorated LavaUI window with frost behind it
/// is four: contents, title bar, shadow, frost — and the frost is output-sized
/// no matter how small the window is.
struct WindowsPage: View {
    let store: GpuStore
    let mono: UIFont
    let small: UIFont

    var body: some View {
        let report = store.report
        return ScrollView {
            VStack(spacing: 16) {
                Card("Windows (\(report.windows.count))") {
                    if report.windows.isEmpty {
                        Text("No windows — nothing is being drawn.",
                             color: Theme.current.textDim)
                    }
                    ForEach(report.windows, id: \.id) { window in
                        VStack(spacing: 4) {
                            HStack(alignment: .center, spacing: 10) {
                                Text(window.title.isEmpty
                                        ? "window \(window.id)"
                                        : window.title,
                                     color: Theme.current.textPrimary)
                                Spacer()
                                Text("\(window.width)x\(window.height)",
                                     color: Theme.current.textDim)
                                Text(humanBytes(window.bytes),
                                     color: Theme.current.textPrimary)
                            }
                            Bar(fraction: report.ownBytes == 0 ? 0
                                    : Double(window.bytes) / Double(report.ownBytes),
                                color: Theme.current.accent, width: 420)
                            Text(breakdown(for: window.id),
                                 color: Theme.current.textDim)
                                .font(mono)
                        }
                    }
                }
            }
            .font(small)
        }
    }

    /// The window's own allocations, one line, so the size of the attachments is
    /// visible without leaving the page.
    private func breakdown(for windowId: UInt32) -> String {
        store.report.allocations
            .filter { $0.windowId == windowId }
            .sorted { $0.bytes > $1.bytes }
            .prefix(6)
            .map { alloc in
                let samples = alloc.samples > 1 ? " x\(alloc.samples)" : ""
                return "\(alloc.category)\(samples) \(humanBytes(alloc.bytes))"
            }
            .joined(separator: "   ")
    }
}

// MARK: - Atlases

/// The atlases, as numbers and — once written — as pictures.
///
/// The picture is the point of this page. "60% packed" says nothing about
/// whether that 60% is one font at nine sizes or a UI's worth of glyphs, and
/// the difference decides whether the atlas is doing its job.
struct AtlasPage: View {
    let store: GpuStore
    let mono: UIFont
    let small: UIFont

    var body: some View {
        let atlases = store.report.atlases
        return ScrollView {
            VStack(spacing: 16) {
                if atlases.isEmpty {
                    Card("Atlases") {
                        Text("No atlas pages.", color: Theme.current.textDim)
                    }
                }
                ForEach(Array(atlases.enumerated()), id: \.offset) { pair in
                    let atlas = pair.element
                    Card(title(for: atlas)) {
                        Row(label: "Size",
                            value: "\(atlas.width)x\(atlas.height)",
                            detail: humanBytes(atlas.bytes))
                        Row(label: atlas.kind == 0 ? "Rows packed" : "Cells used",
                            value: atlas.kind == 0
                                ? "\(atlas.fillPercent)%"
                                : "\(atlas.slotsUsed)/\(atlas.slotsTotal)",
                            detail: atlas.kind == 0
                                ? "\(atlas.glyphs) glyph(s), \(atlas.faces) face(s)"
                                : "\(atlas.cellSize)px cells")
                        Bar(fraction: Double(atlas.fillPercent) / 100,
                            color: Theme.current.accent, width: 420)
                        if atlas.pngPath.isEmpty {
                            Text("Press “Write atlas PNGs” to see the pixels.",
                                 color: Theme.current.textDim)
                        } else {
                            Text(atlas.pngPath, color: Theme.current.textDim)
                                .font(mono)
                            // Square-ish and bounded: an atlas can be 16k on a
                            // side, and the window is not.
                            Image(path: atlas.pngPath,
                                  width: .pt(420),
                                  height: .pt(420 * aspect(atlas)),
                                  placeholder: Theme.current.inset,
                                  placeholderCornerRadius: 6,
                                  contentMode: .fit)
                        }
                    }
                }
            }
            .font(small)
        }
    }

    private func title(for atlas: GpuAtlas) -> String {
        atlas.kind == 0
            ? "Glyph atlas (generation \(atlas.generation))"
            : "Image atlas, page \(atlas.page)"
    }

    private func aspect(_ atlas: GpuAtlas) -> Float {
        guard atlas.width > 0 else { return 1 }
        return Float(atlas.height) / Float(atlas.width)
    }
}

// MARK: - Textures

/// The shared cache: what is resident, and why it still is.
///
/// `refs` is the answer to "why". Zero means dormant — nothing is using it and
/// it is kept only in case something asks again, which is exactly the policy
/// worth arguing with when the cache is large.
struct TexturePage: View {
    let store: GpuStore
    let mono: UIFont
    let small: UIFont

    var body: some View {
        let report = store.report
        return ScrollView {
            VStack(spacing: 16) {
                Card("Cache") {
                    Row(label: "Entries", value: "\(report.textureCount)",
                        detail: humanBytes(report.textureBytes), emphasis: true)
                    Row(label: "Dormant",
                        value: humanBytes(report.dormantBytes),
                        detail: "budget \(humanBytes(report.dormantBudgetBytes))")
                    Bar(fraction: report.dormantBudgetBytes == 0 ? 0
                            : Double(report.dormantBytes)
                                / Double(report.dormantBudgetBytes),
                        color: Theme.current.textMuted, width: 420)
                    Row(label: "Revived without a decode",
                        value: "\(report.cacheHits)",
                        detail: "\(report.cacheEvictions) eviction(s)")
                }

                Card("Largest entries") {
                    if report.textures.isEmpty {
                        Text("Nothing cached.", color: Theme.current.textDim)
                    }
                    ForEach(report.textures, id: \.key) { texture in
                        HStack(alignment: .center, spacing: 10) {
                            Text(texture.key, color: Theme.current.textSecondary,
                                 lineLimit: 1)
                                .font(mono)
                            Spacer()
                            Text("\(texture.width)x\(texture.height)",
                                 color: Theme.current.textDim)
                            Text(state(texture), color: Theme.current.textDim)
                            Text(humanBytes(texture.bytes),
                                 color: Theme.current.textPrimary)
                        }
                    }
                }
            }
            .font(small)
        }
    }

    private func state(_ texture: GpuTexture) -> String {
        var parts: [String] = []
        if texture.dormant { parts.append("dormant") }
        if texture.atlased { parts.append("atlased") }
        parts.append("refs \(texture.refCount)")
        if texture.windowPins > 0 { parts.append("pins \(texture.windowPins)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Allocations

/// Everything, largest first. The page to open when the summary does not
/// explain the total.
struct AllocationPage: View {
    let store: GpuStore
    let mono: UIFont
    let small: UIFont

    var body: some View {
        let allocations = store.report.allocations
        return ScrollView {
            VStack(spacing: 16) {
                Card("Allocations (\(allocations.count))") {
                    ForEach(Array(allocations.enumerated()), id: \.offset) { pair in
                        let alloc = pair.element
                        HStack(alignment: .center, spacing: 10) {
                            Text(humanBytes(alloc.bytes),
                                 color: Theme.current.textPrimary)
                                .font(mono)
                            Text(alloc.category, color: Theme.current.textSecondary)
                            if alloc.windowId != 0 {
                                Text("w\(alloc.windowId)", color: Theme.current.textDim)
                            }
                            Spacer()
                            Text(shape(alloc), color: Theme.current.textDim)
                            Text(alloc.detail, color: Theme.current.textDim,
                                 lineLimit: 1)
                        }
                    }
                }
            }
            .font(small)
        }
    }

    private func shape(_ alloc: GpuAllocation) -> String {
        guard alloc.isImage else { return "buffer" }
        var text = "\(alloc.width)x\(alloc.height)"
        if alloc.samples > 1 { text += " x\(alloc.samples)" }
        if alloc.mipLevels > 1 { text += " \(alloc.mipLevels) mips" }
        if alloc.retiring { text += " · retiring" }
        return text
    }
}
#endif
