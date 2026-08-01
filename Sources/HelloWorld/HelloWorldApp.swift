import Foundation
import LavaUI

#if canImport(CxxCanvas)

/// Runs the LavaUI widget playground (`DemoExample`).
@main
struct HelloWorldApp {
    static func main() {
        guard let editor = LavaApp.open(title: "LavaUI · DemoExample") else {
            exit(1)
        }

        let brandImage = ImageStore.loadAsset(
            named: "football-157930.svg_64.png",
            assetsRoot: LavaApp.resolveAssetsRoot(),
            into: editor
        )
        if brandImage == nil {
            FileHandle.standardError.write(Data("warning: brand image failed to load\n".utf8))
        }

        // Chrome the menubar and the demo's own header both drive. Menu
        // closures capture this reference; the view reads the same
        // `@Observable` object — see `DemoSession`.
        let session = DemoSession()

        // First top-level menu is the *application* menu (Chrome: "Google Chrome").
        // Global panels show it next to the window icon; leaving it out looks like
        // a blank clickable slot before View/Help.
        LavaApp.run(
            editor: editor,
            menu: {
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
        ) {
            DemoExample(session: session, brandImage: brandImage)
        }
    }
}

#else

@main
struct HelloWorldApp {
    static func main() {
        FileHandle.standardError.write(
            Data("HelloWorld: LavaUI requires Linux + libcanvas (CxxCanvas).\n".utf8)
        )
        exit(1)
    }
}

#endif
