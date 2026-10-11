import Foundation
import LavaUI

/// The keyboard. Every binding is one a reader already has from a browser or
/// another PDF viewer; nothing is invented.
enum ReaderKeys {
    /// GLFW codes `KeyCode` does not list.
    private enum Extra {
        static let a: Int32 = 65
        static let c: Int32 = 67
        static let f: Int32 = 70
        static let g: Int32 = 71
        static let f3: Int32 = 292
    }

    static func handle(_ event: KeyEvent, session: ReaderSession) -> Bool {
        let primary = KeyMods.contains(event.mods, KeyMods.control)
        let shift = KeyMods.contains(event.mods, KeyMods.shift)

        if primary {
            switch event.key {
            case Extra.f: session.openFind()
            case Extra.g: session.findNext(shift ? -1 : 1)
            case Extra.c: session.copySelection()
            case Extra.a: session.selectPage()
            case KeyCode.o: session.openDialog()
            case KeyCode.equal, KeyCode.kpAdd: session.stepZoom(1)
            case KeyCode.minus, KeyCode.kpSub: session.stepZoom(-1)
            case KeyCode.key0: session.actualSize()
            case KeyCode.home: session.goToStart()
            case KeyCode.end: session.goToEnd()
            default: return false
            }
            return true
        }

        switch event.key {
        case KeyCode.down: session.scroll(dx: 0, dy: ReaderSession.pixelsPerNotch)
        case KeyCode.up: session.scroll(dx: 0, dy: -ReaderSession.pixelsPerNotch)
        case KeyCode.right: session.scroll(dx: ReaderSession.pixelsPerNotch, dy: 0)
        case KeyCode.left: session.scroll(dx: -ReaderSession.pixelsPerNotch, dy: 0)
        case KeyCode.pageDown: session.page(1)
        case KeyCode.pageUp: session.page(-1)
        // Space pages, as in every browser; Shift+Space goes back.
        case KeyCode.space: session.page(shift ? -1 : 1)
        case KeyCode.home: session.goToStart()
        case KeyCode.end: session.goToEnd()
        case KeyCode.escape:
            if session.findOpen { session.closeFind() } else { session.clearSelection() }
        case Extra.f3: session.findNext(shift ? -1 : 1)
        default: return false
        }
        return true
    }
}
