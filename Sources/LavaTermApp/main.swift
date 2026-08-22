import Foundation
import LavaHost
import LavaUI
import LavaTermCore

/// LavaTerm — a minimal terminal emulator built with LavaUI.
///
/// Architecture:
/// - `LavaTermCore` owns the VT grid + ANSI parser (headless, unit-tested)
/// - `PtySession` forks `$SHELL` on a Linux PTY
/// - `TerminalView` paints cells with `Canvas` and routes keys via `FocusManager`
///
/// Client mode (`LAVA_CLIENT=1`): same app under the compositor — no local
/// window/GPU; frames go to a shared-memory arena (see HelloWorldApp).
Theme.current = .dark
WindowBackdrop.current = .blur(radius: 10)

// `LAVA_CLIENT=1` runs under the compositor: no window, no GPU, frames
// published into shared memory for another process to draw. The PTY
// session and view tree are unchanged — only the host differs.
let client = LavaHost.isClient
// Client-framed by default under the compositor: the app draws
// WindowControls + a path strip and owns the drag region, so a second
// compositor title bar would only add a duplicate "LavaTerm" label.
// `LAVA_FRAME=server` puts the server chrome back for comparison.
let editorOrNil = LavaHost.open(title: "LavaTerm", width: 1024, height: 640)
guard let editor = editorOrNil else { exit(1) }

if client {
    FileHandle.standardError.write(
        Data("LavaTerm: client mode (LAVA_CLIENT=1)\n".utf8)
    )
}

/// Prefer a real monospace face for column alignment.
func loadMonoFont(into editor: Editor) -> UIFont? {
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
            // Without this the terminal draws a tofu box for everything the
            // face lacks, which for a Nerd Font is all of braille and most
            // dingbats — Claude Code's spinner and bullets, in other words.
            //
            // Named, not loaded: the chain is 31 MiB of Nerd Font and CJK
            // collection, and loading it here put ~250 ms between the launch
            // and the window — while a prompt needs none of it. Each face is
            // read the first time a character misses everything ahead of it.
            let chain = UIFont.monospaceFallbacks(pixelSize: 15)
            font.useFallbacks(chain, into: editor)
            // The grid's own cell width, by the same measurement
            // `TerminalView` makes, so a glyph borrowed from a narrower face
            // still occupies exactly one column. Set before anything shapes:
            // it changes what shaping returns, and runs are cached.
            let m = font.shapedRun("M").width
            font.cellAdvance = max(1, m > 0 ? m : font.pixelSize * 0.6)
            let named = chain.map(\.name).joined(separator: ", ")
            FileHandle.standardError.write(Data(
                ("LavaTerm: mono font \(path)\n"
                 + "LavaTerm: fallbacks (on demand) \(named)\n").utf8
            ))
            return font
        }
    }
    FileHandle.standardError.write(
        Data("LavaTerm: no monospace font found, falling back to UI face\n".utf8)
    )
    return nil
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
                "Copy",
                id: "edit.copy",
                shortcut: KeyShortcut(KeyCode.c, .primary, .shift)
            ) {
                _ = session.copySelection()
            }
            MenuItem(
                "Paste",
                id: "edit.paste",
                shortcut: KeyShortcut(KeyCode.v, .primary, .shift)
            ) {
                session.paste()
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

LavaHost.run(editor: editor, menu: menu, makeRoot: root)
session.stop()
