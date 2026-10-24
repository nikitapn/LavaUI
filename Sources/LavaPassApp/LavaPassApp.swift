import Foundation
import Glibc
import LavaHost
import LavaUI

@main
struct LavaPassApp {
    static func main() {
        // Password-vault contents must not be exposed through the developer agent.
        let demo = CommandLine.arguments.contains("--demo")
        if !demo { unsetenv("LAVA_AGENT_PORT") }
        AppSettings.configure(appName: demo ? "LavaPassDemo" : "LavaPass")
        Theme.current = .nebula
        guard let editor = LavaHost.open(title: "LavaPass", width: 1120, height: 720) else { return }
        LavaHost.setMinimumSize(editor: editor, width: 900, height: 560)
        let path = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
        let session = PassSession(path: path, demo: demo)
        if demo { FrameTasks.after { session.unlock() } }
        atexit { PassClipboard.clear(); AttachmentFiles.clear() }
        LavaHost.run(editor: editor, menu: {
            MenuBar {
                Menu("Vault", id: "vault") {
                    MenuItem("Open…", id: "vault.open", shortcut: KeyShortcut(KeyCode.o, .primary)) { session.chooseVault() }
                    MenuItem("New Vault…", id: "vault.new") { session.newVault() }
                    MenuItem("Save KDBX 4 Copy…", id: "vault.copy", isEnabled: session.snapshot?.canSaveCopy == true && !session.busy) { session.saveCopy() }
                    MenuSeparator()
                    MenuItem("Lock", id: "vault.lock", shortcut: KeyShortcut(KeyCode.l, .primary)) { session.lock() }
                    MenuItem("Quit", id: "vault.quit", shortcut: KeyShortcut(KeyCode.q, .primary)) {
                        session.lock(); editor.requestClose()
                    }
                }
                Menu("Entry", id: "entry") {
                    MenuItem("New Entry", id: "entry.new", shortcut: KeyShortcut(KeyCode.n, .primary), isEnabled: session.writable) { session.newEntry() }
                    MenuItem("Edit", id: "entry.edit", isEnabled: session.writable && session.selectedEntry != nil) { session.editEntry() }
                    MenuItem("Copy Password", id: "entry.copy", isEnabled: session.selectedEntry != nil && !session.busy) { session.copyPassword() }
                }
            }
        }, onRawKey: { event in
            session.activity()
            if event.x > 0, event.button == KeyCode.escape {
                session.draft = nil; session.showPassword = false; session.groupName = nil
                session.confirmRecycle = false; FocusManager.clear(); return true
            }
            return false
        }, makeRoot: { PassView(session: session) })
        session.lock()
    }
}
