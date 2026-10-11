import Foundation
import LavaUI

/// The keyboard. Every binding is one a reader already has from a browser or
/// another PDF viewer; nothing is invented.
enum ReaderKeys {
    static func handle(_ event: KeyEvent, session: ReaderSession) -> Bool {
        let primary = KeyMods.contains(event.mods, KeyMods.control)
        let shift = KeyMods.contains(event.mods, KeyMods.shift)
        let alt = KeyMods.contains(event.mods, KeyMods.alt)

        // Back after following a link: the browser's key, and the mouse's
        // back button's key on most desktops.
        if alt, event.key == KeyCode.left {
            session.goBack()
            return true
        }

        if primary {
            switch event.key {
            case KeyCode.f: session.openFind()
            case KeyCode.g: session.findNext(shift ? -1 : 1)
            case KeyCode.c: session.copySelection()
            case KeyCode.a: session.selectPage()
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
        case KeyCode.f3: session.findNext(shift ? -1 : 1)
        case KeyCode.f9: session.toggleSidebar()
        default: return false
        }
        return true
    }
}
