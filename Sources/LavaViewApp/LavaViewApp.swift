import Foundation
import LavaHost
import LavaUI
import LavaViewCore

/// LavaView — a picture, at the size you asked for, and the folder around it.
///
/// Deliberately small. The thing that made the old Windows viewer good was
/// that it opened instantly, showed the picture, and had exactly the controls
/// you needed along the bottom: fit or original size, wheel to zoom where the
/// pointer is, arrows through the folder, and two rotate buttons that could
/// save. Everything that replaced it was larger and did that worse.
///
/// `LavaView path/to/photo.jpg` opens on that file with its folder as the
/// collection. `LavaView a.png b.png` makes the arguments the collection.
/// `LavaView some/folder` opens the first picture in it. No arguments opens
/// empty, ready for a drop.
enum Layout {
    static let initialWidth: Float = 1100
    static let initialHeight: Float = 760
    /// Below this the control bar's groups run out of room and start
    /// wrapping into each other. The host clamps interactive resizes to it,
    /// so the broken shape is simply not reachable.
    static let minWidth: Float = 640
    static let minHeight: Float = 320
}

@main
struct LavaViewApp {
    static func main() {
        AppSettings.configure(appName: "LavaView")

        // Client-framed: the control bar already names the file, and a title
        // bar above it would be a second row saying less. `LAVA_FRAME=server`
        // puts the compositor's frame back.
        guard let editor = LavaHost.open(
            title: "LavaView",
            width: Layout.initialWidth, height: Layout.initialHeight
        ) else { exit(1) }

        LavaHost.setMinimumSize(
            editor: editor, width: Layout.minWidth, height: Layout.minHeight
        )
        Theme.current = .nebula

        // Room for the picture on screen and the two either side of it.
        //
        // The default is sized for an app that shows many small images — a
        // grid of covers, a row of icons — where 256 MB is hundreds of them.
        // Here one 24-megapixel photograph is 96 MB, so three of them do not
        // fit, and the cache would spend the whole session evicting the
        // picture being looked at to make room for the one being read ahead.
        // A viewer holds a handful of pictures at most; this is what that
        // costs, and `ImageStore` still evicts down to it.
        ImageStore.budgetBytes = 512 * 1024 * 1024

        let session = ViewerSession(
            editor: editor, folder: folder(from: CommandLine.arguments.dropFirst())
        )

        LavaHost.run(
            editor: editor,
            menu: {
                MenuBar {
                    Menu("LavaView", id: "app") {
                        MenuItem("About LavaView", id: "app.about") {
                            FileHandle.standardError.write(Data(
                                "LavaView · an image viewer built on LavaUI\n".utf8
                            ))
                        }
                        MenuSeparator()
                        MenuItem(
                            "Quit", id: "app.quit",
                            shortcut: KeyShortcut(KeyCode.q, .primary)
                        ) { editor.requestClose() }
                    }
                    Menu("File", id: "file") {
                        MenuItem(
                            "Open…", id: "file.open",
                            shortcut: KeyShortcut(KeyCode.o, .primary)
                        ) { session.openDialog() }
                        MenuItem("Reload Folder", id: "file.reload") {
                            session.reloadFolder()
                        }
                        MenuSeparator()
                        MenuItem(
                            "Save Rotation", id: "file.save",
                            shortcut: KeyShortcut(KeyCode.s, .primary)
                        ) { session.requestSave() }
                        MenuItem("Save a Copy…", id: "file.save-copy") {
                            session.saveCopy()
                        }
                    }
                    Menu("View", id: "view") {
                        MenuItem("Fit to Window", id: "view.fit") {
                            session.setMode(.fit)
                        }
                        MenuItem("Original Size", id: "view.actual") {
                            session.setMode(.actual)
                        }
                        MenuSeparator()
                        MenuItem("Zoom In", id: "view.zoom-in") { session.stepZoom(1) }
                        MenuItem("Zoom Out", id: "view.zoom-out") { session.stepZoom(-1) }
                        MenuSeparator()
                        MenuItem("Rotate Left", id: "view.rotate-left") {
                            session.rotateLeft()
                        }
                        MenuItem("Rotate Right", id: "view.rotate-right") {
                            session.rotateRight()
                        }
                    }
                    Menu("Go", id: "go") {
                        MenuItem("Next Image", id: "go.next") { session.step(1) }
                        MenuItem("Previous Image", id: "go.previous") { session.step(-1) }
                        MenuSeparator()
                        MenuItem("First", id: "go.first") { session.jump(to: 0) }
                        MenuItem("Last", id: "go.last") {
                            session.jump(to: session.folder.count - 1)
                        }
                    }
                }
            },
            makeRoot: { ViewerView(session: session) }
        )
    }

    /// Turns the command line into a collection.
    ///
    /// One argument is a *position*, not a filter — open the file and take its
    /// neighbours with it, because the next thing anyone does after opening a
    /// photograph is press Right. Several arguments are the collection
    /// themselves: a user who listed three files does not want the other four
    /// hundred in the folder.
    private static func folder(from arguments: ArraySlice<String>) -> ImageFolder {
        let paths = arguments.filter { !$0.hasPrefix("-") }
        switch paths.count {
        case 0: return ImageFolder()
        case 1: return ImageFolder.around(path: paths[0])
        default: return ImageFolder.explicit(paths: paths)
        }
    }
}
