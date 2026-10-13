import Foundation
import LavaHost
import LavaUI

/// LavaPDF — a PDF reader.
///
/// Pages are rasterised by poppler on worker threads, in tiles at √2 zoom
/// steps, and handed to whoever draws — the compositor in client mode, the
/// built-in renderer windowed — as raw pixels (`GPUResourceHost.uploadPixels`).
/// Selection, copy and find work off poppler's text layer, drawn over the
/// tiles. See `LavaPDFCore` for the parts with tests.
///
/// `LavaPDF file.pdf` opens it; no argument opens empty, ready for a drop.
enum Layout {
    static let initialWidth: Float = 980
    static let initialHeight: Float = 900
    static let minWidth: Float = 480
    static let minHeight: Float = 320
}

@main
struct LavaPDFApp {
    static func main() {
        AppSettings.configure(appName: "LavaPDF")

        guard let editor = LavaHost.open(
            title: "LavaPDF", width: Layout.initialWidth, height: Layout.initialHeight
        ) else { exit(1) }
        LavaHost.setMinimumSize(editor: editor, width: Layout.minWidth, height: Layout.minHeight)

        // A compositor's host takes an upload from any thread; the built-in
        // renderer's device is the main thread's alone.
        let session = ReaderSession(
            host: editor.resources, uploadsOffMain: editor.resources !== editor
        )
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            session.open(path: path)
        }

        LavaHost.run(
            editor: editor,
            menu: {
                MenuBar {
                    Menu("Reader", id: "app") {
                        MenuItem(
                            "Quit", id: "app.quit", shortcut: KeyShortcut(KeyCode.q, .primary)
                        ) { editor.requestClose() }
                    }
                    Menu("File", id: "file") {
                        MenuItem(
                            "Open…", id: "file.open", shortcut: KeyShortcut(KeyCode.o, .primary)
                        ) { session.openDialog() }
                    }
                    Menu("Edit", id: "edit") {
                        MenuItem("Copy", id: "edit.copy") { session.copySelection() }
                        MenuItem("Find…", id: "edit.find") { session.openFind() }
                    }
                    Menu("View", id: "view") {
                        MenuItem("Contents", id: "view.contents") { session.toggleSidebar() }
                        MenuSeparator()
                        MenuItem("Fit Width", id: "view.fit-width") { session.setMode(.fitWidth) }
                        MenuItem("Fit Page", id: "view.fit-page") { session.setMode(.fitPage) }
                        MenuItem("Actual Size", id: "view.actual") { session.actualSize() }
                        MenuSeparator()
                        MenuItem("Zoom In", id: "view.zoom-in") { session.stepZoom(1) }
                        MenuItem("Zoom Out", id: "view.zoom-out") { session.stepZoom(-1) }
                    }
                    Menu("Go", id: "go") {
                        MenuItem("Back", id: "go.back") { session.goBack() }
                        MenuSeparator()
                        MenuItem("First Page", id: "go.first") { session.goToStart() }
                        MenuItem("Last Page", id: "go.last") { session.goToEnd() }
                        MenuItem("Next Page", id: "go.next") { session.goTo(page: session.currentPage + 1) }
                        MenuItem("Previous Page", id: "go.previous") { session.goTo(page: session.currentPage - 1) }
                    }
                }
            },
            makeRoot: { ReaderView(session: session) }
        )
    }
}
