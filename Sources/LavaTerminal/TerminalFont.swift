import Foundation
import LavaUI

/// The face a terminal draws in.
public enum TerminalFont {
    /// Prefers a real monospace face for column alignment, with the
    /// monospace fallback chain named (not loaded) behind it, and its cell
    /// advance pinned to the grid's. Nil when no candidate is installed.
    public static func load(into editor: Editor, pixelSize: Float = 15) -> UIFont? {
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
            if let font = UIFont(path: path, pixelSize: pixelSize) {
                _ = font.registerWithEngine(editor)
                // Without this the terminal draws a tofu box for everything the
                // face lacks, which for a Nerd Font is all of braille and most
                // dingbats — Claude Code's spinner and bullets, in other words.
                //
                // Named, not loaded: the chain is 31 MiB of Nerd Font and CJK
                // collection, and loading it here put ~250 ms between the launch
                // and the window — while a prompt needs none of it. Each face is
                // read the first time a character misses everything ahead of it.
                let chain = UIFont.monospaceFallbacks(pixelSize: pixelSize)
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
}
