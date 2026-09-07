import Foundation
import LavaUI
import LavaViewCore

/// The keyboard, in one place.
///
/// Every binding here is one somebody already has in their fingers from a
/// different viewer: the arrows and Space from a slideshow, `+`/`-`/`0` from a
/// browser, `,` and `.` from the Windows viewer's rotate pair. Nothing is
/// invented.
enum ViewerKeys {
    /// Codes LavaUI's `KeyCode` does not list. They are GLFW values, which is
    /// what both hosts forward, so they can be spelled here rather than added
    /// to the framework for one app.
    private enum Extra {
        static let f: Int32 = 70
        static let r: Int32 = 82
        static let bracketLeft: Int32 = 91
        static let bracketRight: Int32 = 93
    }

    static func handle(_ event: KeyEvent, session: ViewerSession) -> Bool {
        // A pending question owns the keyboard: Escape and Enter must answer
        // it rather than pan the picture behind it.
        if session.pendingSave != nil {
            switch event.key {
            case KeyCode.escape:
                session.cancelSave()
                return true
            case KeyCode.enter:
                session.confirmSave()
                return true
            default:
                return true
            }
        }

        switch event.key {
        // Walking the folder. Space and Backspace are here because a
        // slideshow taught everyone that they page forwards and back.
        case KeyCode.right, KeyCode.pageDown, KeyCode.space:
            session.step(1)
        case KeyCode.left, KeyCode.pageUp, KeyCode.backspace:
            session.step(-1)
        case KeyCode.home:
            session.jump(to: 0)
        case KeyCode.end:
            session.jump(to: session.folder.count - 1)

        // Zoom. Both the main row and the keypad, because `+` is on the
        // keypad for the people who reach for it there.
        case KeyCode.equal, KeyCode.kpAdd:
            session.stepZoom(1)
        case KeyCode.minus, KeyCode.kpSub:
            session.stepZoom(-1)
        case KeyCode.key0, KeyCode.key1:
            session.setMode(.actual)
        case Extra.f:
            session.setMode(.fit)

        // Turning. `,`/`.` is the Windows viewer's pair; `[`/`]` is what
        // people who have used a photo manager reach for instead.
        case KeyCode.comma, Extra.bracketLeft:
            session.rotateLeft()
        case KeyCode.period, Extra.bracketRight:
            session.rotateRight()

        case KeyCode.s where event.control:
            session.requestSave()
        case KeyCode.o where event.control:
            session.openDialog()
        case Extra.r where event.control:
            session.reloadFolder()

        case KeyCode.escape:
            session.dismissNotice()

        default:
            return false
        }
        return true
    }
}
