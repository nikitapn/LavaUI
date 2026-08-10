import Foundation
import LavaUI
import LavaTermCore
#if canImport(LavaClient)
import LavaClient
#endif

/// LavaTerm — a minimal terminal emulator built with LavaUI.
///
/// Architecture:
/// - `LavaTermCore` owns the VT grid + ANSI parser (headless, unit-tested)
/// - `PtySession` forks `$SHELL` on a Linux PTY
/// - `TerminalView` paints cells with `Canvas` and routes keys via `FocusManager`
///
/// Client mode (`LAVA_CLIENT=1`): same app under the compositor — no local
/// window/GPU; frames go to a shared-memory arena (see HelloWorldApp).
@main
struct LavaTermApp {
    static func main() {
        Theme.current = .dark

        // `LAVA_CLIENT=1` runs under the compositor: no window, no GPU, frames
        // published into shared memory for another process to draw. The PTY
        // session and view tree are unchanged — only the host differs.
        let client = ProcessInfo.processInfo.environment["LAVA_CLIENT"] == "1"
        #if canImport(LavaClient)
        // Client-framed by default under the compositor: the app draws
        // WindowControls + a path strip and owns the drag region, so a second
        // compositor title bar would only add a duplicate "LavaTerm" label.
        // `LAVA_FRAME=server` puts the server chrome back for comparison.
        let serverFrame =
            ProcessInfo.processInfo.environment["LAVA_FRAME"] == "server"
        let editorOrNil = client
            ? LavaClient.open(
                title: "LavaTerm", width: 1024, height: 640,
                frame: serverFrame ? .server : .client
              )
            : LavaApp.open(title: "LavaTerm", width: 1024, height: 640)
        #else
        let editorOrNil = client
            ? LavaApp.openClient(width: 1024, height: 640)
            : LavaApp.open(title: "LavaTerm", width: 1024, height: 640)
        #endif
        guard let editor = editorOrNil else { exit(1) }

        if client {
            FileHandle.standardError.write(
                Data("LavaTerm: client mode (LAVA_CLIENT=1)\n".utf8)
            )
        }

        let mono = loadMonoFont(into: editor)
            ?? FontStore.default
        guard let mono else {
            FileHandle.standardError.write(
                Data("LavaTerm: no font available\n".utf8)
            )
            exit(1)
        }

        let session = TerminalSession()
        FrameTasks.after {
            session.start()
        }

        let menu = {
            MenuBar {
                Menu("LavaTerm", id: "app") {
                    MenuItem("About LavaTerm", id: "app.about") {
                        FileHandle.standardError.write(
                            Data("LavaTerm · LavaUI terminal emulator\n".utf8)
                        )
                    }
                    MenuSeparator()
                    MenuItem(
                        "Quit",
                        id: "app.quit",
                        shortcut: KeyShortcut(KeyCode.q, .primary)
                    ) {
                        session.stop()
                        editor.requestClose()
                    }
                }
                Menu("Edit", id: "edit") {
                    MenuItem(
                        "Paste",
                        id: "edit.paste",
                        shortcut: KeyShortcut(KeyCode.v, .primary)
                    ) {
                        let text = editor.clipboardText
                        if !text.isEmpty {
                            session.write(text)
                        }
                    }
                }
                Menu("View", id: "view") {
                    MenuItem(
                        "Toggle Theme",
                        id: "view.theme",
                        shortcut: KeyShortcut(KeyCode.t, .primary)
                    ) {
                        Theme.current = (Theme.current == .dark) ? .light : .dark
                        ViewInvalidation.markDirty()
                    }
                }
            }
        }

        let root = {
            TerminalView(session: session, mono: mono)
        }

        #if canImport(LavaClient)
        if client {
            // Never returns: process exits when the compositor surface goes away.
            LavaClient.run(editor: editor, menu: menu, makeRoot: root)
        }
        #endif

        LavaApp.run(editor: editor, menu: menu, makeRoot: root)
        session.stop()
    }

    /// Prefer a real monospace face for column alignment.
    private static func loadMonoFont(into editor: Editor) -> UIFont? {
        let candidates = [
            "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
            "/usr/share/fonts/TTF/JetBrainsMonoNLNerdFontMono-Regular.ttf",
            "/usr/share/fonts/TTF/HackNerdFontMono-Regular.ttf",
            "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
            "/usr/share/fonts/TTF/NotoMonoNerdFontMono-Regular.ttf",
        ]
        for path in candidates {
            if let font = UIFont(path: path, pixelSize: 15) {
                _ = font.registerWithEngine(editor)
                FileHandle.standardError.write(
                    Data("LavaTerm: mono font \(path)\n".utf8)
                )
                return font
            }
        }
        FileHandle.standardError.write(
            Data("LavaTerm: no monospace font found, falling back to UI face\n".utf8)
        )
        return nil
    }
}
