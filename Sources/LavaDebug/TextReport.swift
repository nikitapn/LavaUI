#if canImport(LavaIDL)
import Foundation
import LavaIDL
import LavaUI

/// The report as text, for `--once`.
///
/// Worth having as well as the window: a compositor whose VRAM is exhausted may
/// not be able to open another window, and this is the version that still works
/// when the answer is most wanted. Deliberately close to the compositor's own
/// `LAVA_VRAM_STATS` dump, so a log line and a terminal line look alike.
func textReport(_ report: GpuReport, verbose: Bool) -> String {
    var out: [String] = []
    out.append("─── GPU memory ─────────────────────────────────────────────")
    out.append("\(report.deviceName), \(report.samples)x MSAA "
               + "(device allows \(report.maxSamples)x)")
    out.append("  driver attributes  \(humanBytes(report.heapUsageBytes)) of "
               + "\(humanBytes(report.heapBudgetBytes)) budget, "
               + "\(humanBytes(report.heapSizeBytes)) installed")
    out.append("  allocator holds    \(humanBytes(report.vmaBlockBytes)), "
               + "\(humanBytes(report.vmaAllocatedBytes)) handed out")
    out.append("  accounted for      \(humanBytes(report.ownBytes)) over "
               + "\(report.allocations.count) allocation(s)")
    if report.retiringBytes > 0 {
        out.append("  awaiting retire    \(humanBytes(report.retiringBytes))")
    }
    if report.foreignBytes > 0 {
        out.append("  imported (not ours) \(humanBytes(report.foreignBytes))")
    }

    var byCategory: [String: UInt64] = [:]
    for alloc in report.allocations where !alloc.foreign {
        byCategory[alloc.category, default: 0] += alloc.bytes
    }
    out.append("by category:")
    for entry in byCategory.sorted(by: { $0.value > $1.value }) {
        out.append("  " + entry.key.padding(toLength: 18, withPad: " ",
                                            startingAt: 0)
                   + humanBytes(entry.value).leftPadded(to: 10)
                   + "  \(percent(entry.value, of: report.ownBytes))%")
    }

    out.append("windows:")
    for window in report.windows {
        out.append("  \(String(window.id).leftPadded(to: 4))  "
                   + "\(window.width)x\(window.height)".padding(toLength: 12,
                                                                withPad: " ",
                                                                startingAt: 0)
                   + (window.presenting ? "presenting  " : "offscreen   ")
                   + humanBytes(window.bytes).leftPadded(to: 10)
                   + (window.title.isEmpty ? "" : "  " + window.title))
    }

    out.append("atlases:")
    for atlas in report.atlases {
        if atlas.kind == 0 {
            out.append("  glyph  \(atlas.width)x\(atlas.height)  R8  "
                       + humanBytes(atlas.bytes).leftPadded(to: 10)
                       + "  \(atlas.fillPercent)% packed, \(atlas.glyphs) glyph(s), "
                       + "\(atlas.faces) face(s), generation \(atlas.generation)")
        } else {
            out.append("  image  page \(atlas.page)  \(atlas.width)x\(atlas.height)"
                       + "  RGBA8  " + humanBytes(atlas.bytes).leftPadded(to: 10)
                       + "  \(atlas.slotsUsed)/\(atlas.slotsTotal) cells of "
                       + "\(atlas.cellSize)px")
        }
        if !atlas.pngPath.isEmpty { out.append("         → \(atlas.pngPath)") }
    }

    out.append("texture cache: \(report.textureCount) entr(ies), "
               + "\(humanBytes(report.textureBytes)) resident, "
               + "\(humanBytes(report.dormantBytes)) dormant of "
               + "\(humanBytes(report.dormantBudgetBytes)) budget, "
               + "\(report.cacheHits) hit(s), \(report.cacheEvictions) eviction(s)")

    guard verbose else { return out.joined(separator: "\n") }

    out.append("allocations:")
    for alloc in report.allocations {
        var line = "  " + humanBytes(alloc.bytes).leftPadded(to: 10) + "  "
            + alloc.category.padding(toLength: 18, withPad: " ", startingAt: 0)
        if alloc.windowId != 0 { line += " w\(alloc.windowId)" }
        if alloc.isImage {
            line += "  \(alloc.width)x\(alloc.height)"
            if alloc.samples > 1 { line += " x\(alloc.samples)" }
            if alloc.mipLevels > 1 { line += " \(alloc.mipLevels) mips" }
        }
        if alloc.retiring { line += "  [retiring]" }
        if !alloc.detail.isEmpty { line += "  " + alloc.detail }
        out.append(line)
    }

    out.append("textures:")
    for texture in report.textures {
        var line = "  " + humanBytes(texture.bytes).leftPadded(to: 10)
            + "  \(texture.width)x\(texture.height)  refs \(texture.refCount)"
            + " pins \(texture.windowPins)"
        if texture.atlased { line += "  atlased" }
        if texture.dormant { line += "  dormant" }
        out.append(line + "  " + texture.key)
    }
    return out.joined(separator: "\n")
}

private extension String {
    /// Right-aligned in `width`, for a column of byte figures.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

/// Prefer a real monospace face; nil when the machine has none installed.
///
/// The same list `LavaTerm` uses, and for the same reason: these are the faces
/// an Arch or Debian box actually has, and a table of numbers wants columns that
/// line up.
func loadMonoFont(pixelSize: Float) -> UIFont? {
    let candidates = [
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
        "/usr/share/fonts/TTF/HackNerdFontMono-Regular.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
    ]
    for path in candidates {
        if let font = UIFont(path: path, pixelSize: pixelSize) { return font }
    }
    return nil
}
#endif
