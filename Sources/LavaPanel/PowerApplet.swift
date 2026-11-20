import Foundation
import LavaMenu
import LavaUI

/// The power button's card: who is signed in, then the session's verbs —
/// lock, log out, suspend, restart, shut down. `Taskbar.dc.html`'s
/// "Session" popup.
///
/// The verbs that end something (log out, restart, shut down) still ask
/// first, in the session dialog; this card only says which.
struct SessionCard: View {
    static let width: Float = 280
    static let padding: Float = 8
    /// A row: 7px either side of the design's 21px line.
    static let rowHeight: Float = 35
    static var height: Float {
        // Header (6 + 36 + 10), the rule and the 6 under it, five rows and
        // one separator.
        padding * 2 + 52 + 1 + 6 + rowHeight * 5 + 11
    }

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let user = NSUserName()
        let modifier: KeyShortcutModifier = session.modKey == "super" ? .command : .option
        let lockKeys = MenuShortcutLabel.format(KeyShortcut(KeyCode.l, modifier))

        return PopupCard(padding: Self.padding, radius: 20) {
            HStack(padding: 0, alignment: .center, spacing: 10) {
                HStack(width: .pt(36), height: .pt(36), padding: 0, alignment: .center,
                       spacing: 0) {
                    Spacer()
                    Text(String(user.prefix(1)).uppercased(), color: palette.bar.onAccent,
                         font: fonts.heading16)
                    Spacer()
                }
                .background(palette.bar.accent)
                .cornerRadius(18)
                VStack(padding: 0, spacing: 1) {
                    Text(user, color: palette.bar.text, font: fonts.title15, lineLimit: 1)
                    Text("Lava session", color: palette.bar.textSoft, font: fonts.caption12)
                }
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))

            CardDivider()
            VStack(padding: 0, spacing: 0) {
                SessionRow(title: "Lock screen", icon: MenuGlyphs.lock, shortcut: lockKeys,
                           id: "session.lock") {
                    session.activate(DesktopMenuID.lock)
                }
                SessionRow(title: "Log out…", icon: MenuGlyphs.logout, id: "session.logout") {
                    session.setDialog(.logout)
                }
                Canvas(label: "separator", width: .pct(100), height: .pt(11)) { list, frame in
                    list.rect(x: frame.x + 10, y: frame.y + 5, w: max(0, frame.w - 20), h: 1,
                              color: palette.bar.divider)
                }
                SessionRow(title: "Suspend", icon: MenuGlyphs.moon, id: "session.suspend") {
                    session.requestPower(.sleep)
                }
                SessionRow(title: "Restart…", icon: MenuGlyphs.restart, id: "session.restart") {
                    session.setDialog(.restart)
                }
                SessionRow(title: "Shut down…", icon: MenuGlyphs.power, danger: true,
                           id: "session.shutdown") {
                    session.setDialog(.powerOff)
                }
            }
            .padding(EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))
        }
        .agentId("session.card")
    }
}

/// One verb on the card, drawn as the menus draw a row: a glyph column, the
/// title, the shortcut on the right; the accent wash under the pointer.
private struct SessionRow: View {
    var title: String
    var icon: String
    var shortcut: String = ""
    var danger = false
    var id: String
    var action: () -> Void

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let action = action
        return HStack(height: .pt(SessionCard.rowHeight), padding: 0, alignment: .center,
                      spacing: 10, onClick: {
                          session.closeSessionCard()
                          action()
                      }) {
            HStack(width: .pt(18), padding: 0, alignment: .center, spacing: 0) {
                Spacer()
                Icon(icon, size: 16,
                     color: danger ? palette.accent700 : palette.bar.textSoft,
                     strokeWidth: 2.25)
                Spacer()
            }
            Text(title, color: danger ? palette.bar.accentInk : palette.bar.text,
                 font: danger ? fonts.body14Semi : fonts.body14, lineLimit: 1)
                .flexGrow(1)
            if !shortcut.isEmpty {
                Text(shortcut, color: palette.bar.textSoft, font: fonts.caption12)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .hoverBackground(palette.bar.accentSoft)
        .cornerRadius(12)
        .cursor(.pointer)
        .agentId(id)
    }
}
