import Foundation
import LavaUI

struct TabContextMenu: View {
    struct Anchor {
        let id: Int
        let x: Float
        let y: Float
    }

    let session: EditorSession
    let document: EditorDocument
    let style: MenuBarStyle
    let dismiss: () -> Void

    private enum Action: String {
        case pin, reveal, close, closeRight, closeAll, closeOthers, copyPath, copyRelative, containingFolder

        func item(_ title: String, enabled: Bool = true) -> MenuEntry {
            .item(MenuItemModel(id: MenuID(rawValue), title: title, isEnabled: enabled))
        }
    }

    @ViewBuilder var body: some View {
        let url = document.url?.standardizedFileURL
        let relative = url.flatMap { session.project?.tree.path(of: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let previews = session.previewOptions(for: document)
        let previewItems: [MenuEntry] = previews.map { option in
            let title = previews.count == 1 ? "Open Preview" : "Open Preview · " + option.title
            return .item(MenuItemModel(id: MenuID(option.id), title: title))
        }
        let panel = MenuDropdownPanel(
            entries: [
                Action.pin.item(document.tabState == .pinned ? "Unpin" : "Pin"),
            ] + previewItems + [
                Action.reveal.item("Reveal in Explorer View", enabled: relative != nil),
                .separator,
                Action.close.item("Close Tab"),
                Action.closeRight.item("Close to Right"),
                Action.closeAll.item("Close All"),
                Action.closeOthers.item("Close Others"),
                .separator,
                Action.copyPath.item("Copy Path", enabled: url != nil),
                Action.copyRelative.item("Copy Relative Path", enabled: relative != nil),
                Action.containingFolder.item("Open Containing Folder", enabled: url != nil),
            ],
            onActivate: { id in
                dismiss()
                guard let index = session.documents.firstIndex(where: { $0.id == document.id }) else { return }
                if let option = previews.first(where: { $0.id == id.raw }) {
                    session.openPreview(of: index, using: option)
                    return
                }
                guard let action = Action(rawValue: id.raw) else { return }
                switch action {
                case .pin: session.toggleTabPin(index)
                case .reveal:
                    if let url { session.revealInExplorer(url) }
                case .close: session.requestClose(index)
                case .closeRight: session.requestCloseTabs(.right, from: index)
                case .closeAll: session.requestCloseTabs(.all, from: index)
                case .closeOthers: session.requestCloseTabs(.others, from: index)
                case .copyPath:
                    if let url { ClipboardBridge.write(url.path) }
                case .copyRelative:
                    if let relative { ClipboardBridge.write(relative) }
                case .containingFolder:
                    if let url, !Self.launchExplorer(at: url.deletingLastPathComponent()) {
                        session.notice = "Could not launch LavaExplorer"
                    }
                }
            },
            style: style
        )
        if let font = session.fonts.tab { panel.font(font) } else { panel }
    }

    // The same in-window menu measurements as LavaExplorer's pane menus.
    static func style(theme: Theme) -> MenuBarStyle {
        var style = MenuBarStyle.standard(theme: theme)
        style.itemPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 12)
        style.itemCornerRadius = 12
        style.itemHover = theme.selectionFill
        style.itemSpacing = 0
        style.dropdownPadding = 6
        style.dropdownMinWidth = 240
        style.dropdownBackground = theme.inset
        style.dropdownBorder = theme.border
        style.dropdownCornerRadius = 18
        style.dropdownBlur = nil
        return style
    }

    // Match the panel's desktop program lookup and leave Explorer running on its own.
    private static func launchExplorer(at folder: URL) -> Bool {
        let name = "LavaExplorer"
        let directory = CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }
        let candidates = ["", "../debug", "../release"].compactMap { subdirectory in
            directory?.appendingPathComponent(subdirectory).appendingPathComponent(name).path
        }
        for path in candidates + [name] {
            let process = Process()
            if path.contains("/") {
                guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = [folder.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [name, folder.path]
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return true }
        }
        return false
    }
}
