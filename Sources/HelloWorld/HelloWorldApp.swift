import Foundation
import LavaHost
import LavaUI

/// Runs the LavaUI widget playground (`DemoExample`).
@main
struct HelloWorldApp {
    static func main() {
        // `LAVA_CLIENT=1` runs the same demo under the compositor: no window,
        // no GPU, frames published into shared memory for another process to
        // draw. Everything between here and `run` is the app it has always
        // been — the images still load, the menu is still built — which is the
        // property worth having and the reason this is two calls rather than a
        // separate program.
        // Client-framed by default under the compositor: the demo's toolbar is
        // already a 56pt row, and a title bar above it would be a second one
        // saying less. `LAVA_FRAME=server` puts the compositor's strip back,
        // which is the comparison worth being able to make in one keystroke.
        let editorOrNil = LavaHost.open(title: "LavaUI · DemoExample")
        guard let editor = editorOrNil else { exit(1) }

        // Demo art is HelloWorld's own SPM resources, not the engine/LavaUI.
        let brandImage = ImageStore.loadAsset(
            named: "football-157930.svg_64.png",
            bundle: .module,
            into: editor
        )
        if brandImage == nil {
            FileHandle.standardError.write(Data("warning: brand image failed to load\n".utf8))
        }

        let posters = ["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg", "6.jpg", "7.jpg"]
            .compactMap { name -> UIImage? in
                ImageStore.loadAsset(
                    named: name,
                    bundle: .module,
                    into: editor
                ) ?? {
                    FileHandle.standardError.write(
                        Data("warning: poster image failed to load: \(name)\n".utf8)
                    )
                    return nil }()
                }

        // Chrome the menubar and the demo's own header both drive. Menu
        // closures capture this reference; the view reads the same
        // `@Observable` object — see `DemoSession`.
        let session = DemoSession()

        // First top-level menu is the *application* menu (Chrome: "Google Chrome").
        // Global panels show it next to the window icon; leaving it out looks like
        // a blank clickable slot before View/Help.
        // One menu and one root, handed to whichever loop is running. The two
        // take the same arguments deliberately: an app becoming a client is a
        // change of host, not a change of app.
        let menu = {
                MenuBar {
                    Menu("LavaUI", id: "app") {
                        MenuItem("Reset Demo Chrome", id: "app.reset") {
                            session.resetChrome()
                        }
                        MenuSeparator()
                        MenuItem(
                            "Quit",
                            id: "app.quit",
                            shortcut: KeyShortcut(KeyCode.q, .primary)
                        ) {
                            editor.requestClose()
                        }
                    }
                    Menu("View", id: "view") {
                        // Checkmarks come from the same properties the header
                        // toggles write, so the panel reflects the window
                        // whichever one you used last.
                        MenuItem(
                            "Show Navigation",
                            id: "view.nav",
                            isChecked: session.showSidebar
                        ) {
                            session.showSidebar.toggle()
                        }
                        MenuItem(
                            "Show Inspector",
                            id: "view.inspector",
                            isChecked: session.showInspector
                        ) {
                            session.showInspector.toggle()
                        }
                        MenuItem(
                            "Show Banner",
                            id: "view.banner",
                            isChecked: session.showBanner
                        ) {
                            session.showBanner.toggle()
                        }
                        MenuSeparator()
                        MenuItem(
                            "Toggle Theme",
                            id: "view.theme",
                            shortcut: KeyShortcut(KeyCode.t, .primary)
                        ) {
                            // Through the session, not `Theme.current`
                            // directly: the header label reads `lightTheme`,
                            // and writing the theme behind its back is what
                            // used to leave it saying "Dark" on a light window.
                            session.toggleTheme()
                        }
                        MenuSeparator()
                        // No shortcuts here on purpose. Ctrl+Shift+± / 0 are
                        // already handled by `ContentScaleShortcuts`, and menu
                        // matching runs *first* and consumes the event — so
                        // binding the same chord would shadow that path rather
                        // than duplicate it.
                        MenuItem("Zoom In", id: "view.zoom-in") {
                            FontStore.zoomIn(into: editor)
                        }
                        MenuItem("Zoom Out", id: "view.zoom-out") {
                            FontStore.zoomOut(into: editor)
                        }
                        MenuItem("Actual Size", id: "view.zoom-reset") {
                            FontStore.resetScale(into: editor)
                        }
                    }
                    Menu("Help", id: "help") {
                        MenuItem("About LavaUI", id: "help.about") {
                            FileHandle.standardError.write(
                                Data("LavaUI demo — native menu (AppMenu / Vulkan)\n".utf8)
                            )
                        }
                    }
                }
            }
        let root = {
            DemoExample(session: session, brandImage: brandImage, posters: posters)
        }
        LavaHost.run(editor: editor, menu: menu, makeRoot: root)
    }
}
