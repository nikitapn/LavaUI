import Foundation
import LavaUI
import LavaViewCore

/// The panel beside the picture: what the file is, and what the photograph
/// says about how it was taken. Toggled by `I`, the bar's Info button, or View → Photo
/// Info, and remembered between runs.
///
/// Beside rather than over: a panel laid on the picture covers the part of it
/// that the numbers are about, and the canvas refits to the narrower box on
/// its own. Labels sit above their values, not beside them, so a long lens
/// name wraps inside the panel rather than pushing a column into the picture.
struct InfoPanel: View {
    @Bindable var session: ViewerSession

    static let width: Float = 260

    var body: some View {
        let theme = Theme.current
        let info = session.infoForCurrent()
        return ScrollView(.vertical) {
            // The width is stated on the column, not only on the scroll view
            // around it: a value with no space to break at — a folder path —
            // otherwise lays the column out as wide as itself, and the panel
            // grows into the picture to fit it.
            VStack(width: .pt(Self.width), padding: 14, spacing: 14) {
                if let info {
                    section("File", fileRows(info))
                    if let photo = info.photo {
                        section("Photo", photo.rows)
                    } else {
                        Text("No camera information in this file", color: theme.textDim)
                            .agentId("info-no-exif")
                    }
                }
                // Nothing until the first read lands — a fraction of a second,
                // once. Not "Reading…": a label that shows for one frame
                // is a flash, not information.
            }
        }
        // A `ScrollView` fills its parent unless told otherwise, and beside a
        // canvas that also grows it took half the window.
        .flexGrow(0)
        .flexShrink(0)
        .frame(width: .pt(Self.width))
        .background(theme.panel)
        .agentId("info-panel")
    }

    private func fileRows(_ info: ViewerSession.FileInfo) -> [(label: String, value: String)] {
        var rows: [(String, String)] = [("Name", (info.path as NSString).lastPathComponent)]
        // As drawn — after a turn, the turned size — and marked when capped,
        // the same string the title bar shows.
        if !session.dimensions.isEmpty { rows.append(("Dimensions", session.dimensions)) }
        if let bytes = info.bytes {
            rows.append(("Size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if let modified = info.modified {
            rows.append(("Modified", Self.dateFormatter.string(from: modified)))
        }
        rows.append(("Folder", (info.path as NSString).deletingLastPathComponent))
        return rows
    }

    private func section(_ title: String, _ rows: [(label: String, value: String)]) -> some View {
        let theme = Theme.current
        return VStack(spacing: 8) {
            Text(title.uppercased(), color: theme.textSecondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(spacing: 1) {
                    Text(row.label, color: theme.textDim)
                    // Two lines, then an ellipsis: enough for a lens name that
                    // wraps, and a path that will not is cut rather than
                    // widening the panel.
                    Text(row.value, color: theme.textPrimary, lineLimit: 2)
                        .flexShrink(1)
                        .agentId("info-\(row.label.lowercased().replacingOccurrences(of: " ", with: "-"))")
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
