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

        // Phase 2: in-window Vulkan menubar (same IR as future DBusMenu host).
        LavaApp.run(
            editor: editor,
            menu: {
                MenuBar {
                    Menu("View") {
                        MenuItem(
                            "Toggle theme",
                            id: "view.theme",
                            shortcut: KeyShortcut(KeyCode.t, .primary)
                        ) {
                            Theme.current = (Theme.current == .dark) ? .light : .dark
                        }
                        MenuSeparator()
                        MenuItem("Zoom in", id: "view.zoom-in") {
                            // Content scale is handled by Ctrl+= in the loop;
                            // this is a visible menu target for agents/demos.
                            FileHandle.standardError.write(Data("menu: Zoom in\n".utf8))
                        }
                        MenuItem("Zoom out", id: "view.zoom-out") {
                            FileHandle.standardError.write(Data("menu: Zoom out\n".utf8))
                        }
                    }
                    Menu("Help") {
                        MenuItem("About LavaUI", id: "help.about") {
                            FileHandle.standardError.write(
                                Data("LavaUI demo — native menu phase 2 (Vulkan bar)\n".utf8)
                            )
                        }
                    }
                }
            }
        ) {
            DemoExample(brandImage: brandImage)
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
