import Foundation
import LavaArchive
import LavaExplorerCore
import LavaRemote
import LavaUI

/// The questions the explorer asks — what to do about a name already there,
/// a password, a server's address, whether to delete for good — as a card in
/// the middle of the window over a dimmed one, in the design's dialog
/// language: a glyph on a disc, the question in the display face, the fields,
/// and the answers as pills, the expected one solid.
///
/// One card for all of them, showing the first that is waiting, in the order
/// the bars used to stack in. Escape and Enter mean what they meant before:
/// the app's key handler and each field's submit are unchanged.
struct PromptDialog: View {
    @Bindable var session: ExplorerSession

    static let width: Float = 420

    /// Whether anything is waiting to be asked.
    static func isWaiting(_ session: ExplorerSession) -> Bool {
        session.pendingCopy != nil || session.pendingTransfer != nil
            || session.remoteLogin != nil || session.profileDraft != nil
            || session.connectDraft != nil || session.pendingErase != nil
            || session.pendingOverwrite != nil || session.compressDraft != nil
            || session.passwordRequest != nil
    }

    /// Escape: the shown dialog's Cancel.
    static func cancel(_ session: ExplorerSession) {
        if session.pendingCopy != nil {
            session.resolveCopy(nil)
        } else if session.pendingTransfer != nil {
            session.resolveTransfer(nil)
        } else if session.remoteLogin != nil {
            session.cancelLogin()
        } else if session.profileDraft != nil {
            session.profileDraft = nil
        } else if session.connectDraft != nil {
            session.cancelConnect()
        } else if session.pendingErase != nil {
            session.resolveErase(false)
        } else if session.pendingOverwrite != nil {
            session.resolveOverwrite(false)
        } else if session.compressDraft != nil {
            session.cancelCompress()
        } else if session.passwordRequest != nil {
            session.cancelPassword()
        }
    }

    /// Enter with no field to submit: the shown dialog's solid button.
    static func confirm(_ session: ExplorerSession) {
        if session.pendingCopy != nil {
            session.resolveCopy(.keepBoth)
        } else if session.pendingTransfer != nil {
            session.resolveTransfer(.keepBoth)
        } else if session.remoteLogin != nil {
            session.submitLogin()
        } else if session.profileDraft != nil {
            session.createProfile()
        } else if session.connectDraft != nil {
            session.submitConnect()
        } else if session.pendingErase != nil {
            session.resolveErase(true)
        } else if session.pendingOverwrite != nil {
            session.resolveOverwrite(true)
        } else if session.compressDraft != nil {
            session.confirmCompress()
        } else if session.passwordRequest != nil {
            session.submitPassword()
        }
    }

    var body: some View {
        VStack(padding: 0, spacing: 0) {
            content
        }
        .frame(width: .pt(Self.width))
    }

    @ViewBuilder
    private var content: some View {
        if let pending = session.pendingCopy {
            clash(
                pending.plan.clashes.map(\.name), total: pending.plan.items.count,
                folder: pending.folderTitle, prefix: "clash",
                resolve: { session.resolveCopy($0) }
            )
        } else if let plan = session.pendingTransfer {
            clash(
                plan.clashes.map(\.name), total: plan.items.count,
                folder: plan.destinationTitle, prefix: "transfer",
                resolve: { session.resolveTransfer($0) }
            )
        } else if let request = session.remoteLogin {
            login(request)
        } else if session.profileDraft != nil {
            newProfile
        } else if session.connectDraft != nil {
            connect
        } else if let pending = session.pendingErase {
            erase(pending)
        } else if let target = session.pendingOverwrite {
            overwrite(target)
        } else if let draft = session.compressDraft {
            compress(draft)
        } else if let request = session.passwordRequest {
            password(request)
        }
    }

    // MARK: - The questions

    private func clash(
        _ names: [String], total: Int, folder: String, prefix: String,
        resolve: @escaping (ClashChoice?) -> Void
    ) -> some View {
        let one = names.count == 1 && total == 1
        let detail = one
            ? "“\(names[0])” is already in \(folder). Replace it, keep both, or skip it?"
            : "\(names.count) of \(ExplorerSession.items(total)) are already in \(folder). "
                + "Replace them, keep both, or skip them?"
        return VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: DialogGlyphs.copy,
                         title: one ? "Already there" : "Some are already there",
                         detail: detail)
                .agentId("\(prefix)-message")
            DialogButtons {
                DialogButton("Cancel", id: "\(prefix)-cancel") { resolve(nil) }
                DialogButton("Skip", id: "\(prefix)-skip") { resolve(.skip) }
                DialogButton("Replace", id: "\(prefix)-replace") { resolve(.replace) }
                DialogButton("Keep Both", prominent: true,
                             id: prefix == "clash" ? "clash-keep-both" : "transfer-keep-both") {
                    resolve(.keepBoth)
                }
            }
        }
    }

    private func login(_ request: RemoteLoginRequest) -> some View {
        let asksUser = request.server.user == nil
        // SFTP got here only after every key was refused, which is worth
        // saying: on a server with passwords switched off, typing one will
        // not help, and the fix is in ~/.ssh/config.
        let title = request.wrong ? "That did not work" : "Log in to \(request.server.title)"
        let detail = request.wrong
            ? "\(request.server.title) did not take that password. Try again."
            : request.server.scheme == .sftp
                ? "\(request.server.title) did not accept your SSH keys. "
                    + "Type its password, or your key’s passphrase."
                : "This server asks for a password. One that works is kept in your keyring."
        return VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: DialogGlyphs.server, title: title, detail: detail)
                .agentId("login-message")
            VStack(padding: 0, spacing: 8) {
                if asksUser {
                    DialogField(text: session.loginUser, placeholder: "User", autoFocus: true,
                                id: "login-user") { session.submitLogin() }
                }
                DialogField(text: session.loginPassword, placeholder: "Password",
                            autoFocus: !asksUser, secure: true, id: "login-password") {
                    session.submitLogin()
                }
            }
            .padding(EdgeInsets(top: 16, leading: 0, bottom: 0, trailing: 0))
            DialogButtons {
                DialogButton("Cancel", id: "login-cancel") { session.cancelLogin() }
                DialogButton("Connect", prominent: true, id: "login-connect") {
                    session.submitLogin()
                }
            }
        }
    }

    private var newProfile: some View {
        VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: DialogGlyphs.person, title: "New profile",
                         detail: "A profile keeps its own tabs, panes and favorites — one for "
                            + "work, one for home.")
            DialogField(
                text: Binding(get: { session.profileDraft ?? "" },
                              set: { session.profileDraft = $0 }),
                placeholder: "Work, Home, …", autoFocus: true, id: "profile-name"
            ) { session.createProfile() }
                .padding(EdgeInsets(top: 16, leading: 0, bottom: 0, trailing: 0))
            DialogButtons {
                DialogButton("Cancel", id: "profile-cancel") { session.profileDraft = nil }
                DialogButton("Create", prominent: true, id: "create-profile") {
                    session.createProfile()
                }
            }
        }
    }

    private var connect: some View {
        VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: DialogGlyphs.server, title: "Connect to a server",
                         detail: "SFTP, FTP or FTPS. A server you connect to stays under "
                            + "Servers in the sidebar.")
            DialogField(text: session.connectBinding,
                        placeholder: "sftp://user@host, ftp://host or ftps://host",
                        autoFocus: true, id: "connect-address") { session.submitConnect() }
                .padding(EdgeInsets(top: 16, leading: 0, bottom: 0, trailing: 0))
            DialogButtons {
                DialogButton("Cancel", id: "connect-cancel") { session.cancelConnect() }
                DialogButton("Connect", prominent: true, id: "connect-confirm") {
                    session.submitConnect()
                }
            }
        }
    }

    private func erase(_ pending: ExplorerSession.PendingErase) -> some View {
        VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: DialogGlyphs.delete, title: "Delete for good?",
                         detail: pending.message)
                .agentId("erase-message")
            DialogButtons {
                DialogButton("Cancel", id: "erase-cancel") { session.resolveErase(false) }
                DialogButton("Delete", prominent: true, id: "erase-confirm") {
                    session.resolveErase(true)
                }
            }
        }
    }

    private func overwrite(_ target: String) -> some View {
        let name = (target as NSString).lastPathComponent
        return VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: ExplorerGlyphs.page, title: "Replace “\(name)”?",
                         detail: "A file with this name is already here. Replacing it "
                            + "overwrites what is in it.")
            DialogButtons {
                DialogButton("Cancel", id: "overwrite-cancel") { session.resolveOverwrite(false) }
                DialogButton("Replace", prominent: true, id: "overwrite-replace") {
                    session.resolveOverwrite(true)
                }
            }
        }
    }

    private func compress(_ draft: ExplorerSession.CompressDraft) -> some View {
        let what = draft.sources.count == 1
            ? "“\((draft.sources[0] as NSString).lastPathComponent)”"
            : ExplorerSession.items(draft.sources.count)
        let look = ExplorerLook.current
        return VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: DialogGlyphs.archive, title: "Compress",
                         detail: "Pack \(what) into one archive, here beside it.")
            VStack(padding: 0, spacing: 8) {
                DialogField(text: session.compressName, autoFocus: true, selectAll: true,
                            id: "compress-name") { session.confirmCompress() }
                HStack(padding: 0, alignment: .center, spacing: 8) {
                    Text("Format", color: look.soft, font: explorerFonts?.crumb)
                    Spacer()
                    ComboBox(
                        selection: session.compressFormat,
                        items: ArchiveFormat.allCases.map {
                            ComboBoxItem($0.title, tag: $0, detail: "." + $0.fileExtension)
                        },
                        width: .pt(200)
                    )
                    .agentId("compress-format")
                }
                if draft.format.supportsPassword {
                    DialogField(text: session.compressPassword,
                                placeholder: "Password (optional)", secure: true,
                                id: "compress-password") { session.confirmCompress() }
                }
            }
            .padding(EdgeInsets(top: 16, leading: 0, bottom: 0, trailing: 0))
            DialogButtons {
                DialogButton("Cancel", id: "compress-cancel") { session.cancelCompress() }
                DialogButton("Compress", prominent: true, id: "compress-confirm") {
                    session.confirmCompress()
                }
            }
        }
    }

    private func password(_ request: ExplorerSession.PasswordRequest) -> some View {
        let name = "“\(request.archive.name)”"
        return VStack(padding: 0, spacing: 0) {
            DialogHeader(glyph: DialogGlyphs.lock,
                         title: request.wrong ? "Wrong password" : "\(name) is locked",
                         detail: request.wrong
                            ? "That password does not open \(name). Try again."
                            : "Type its password to extract it.")
                .agentId("password-message")
            DialogField(text: session.passwordBinding, autoFocus: true, secure: true,
                        id: "password-field") { session.submitPassword() }
                .padding(EdgeInsets(top: 16, leading: 0, bottom: 0, trailing: 0))
            DialogButtons {
                DialogButton("Cancel", id: "password-cancel") { session.cancelPassword() }
                DialogButton("Extract", prominent: true, id: "password-confirm") {
                    session.submitPassword()
                }
            }
        }
    }
}

// MARK: - Pieces

/// The glyph on its disc, the question, and what it means.
private struct DialogHeader: View {
    let glyph: String
    let title: String
    let detail: String

    var body: some View {
        let look = ExplorerLook.current
        let fonts = explorerFonts
        return HStack(padding: 0, alignment: .start, spacing: 14) {
            HStack(width: .pt(40), height: .pt(40), padding: 0, alignment: .center, spacing: 0) {
                Icon([.path(glyph)], size: 18, color: look.accent800, strokeWidth: 2.25, box: 40)
            }
            .background(look.accent200)
            .cornerRadius(20)
            VStack(flexGrow: 1, padding: 0, spacing: 6) {
                Text(title, color: look.text, font: fonts?.display19)
                Text(detail, color: look.soft, font: fonts?.body)
            }
            .flexShrink(1)
            .padding(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0))
        }
    }
}

/// A text field in a well, the dialog's way.
struct DialogField: View {
    let text: Binding<String>
    var placeholder: String = ""
    var autoFocus = false
    var secure = false
    var selectAll = false
    let id: String
    let submit: () -> Void

    init(text: Binding<String>, placeholder: String = "", autoFocus: Bool = false,
         secure: Bool = false, selectAll: Bool = false, id: String,
         submit: @escaping () -> Void) {
        self.text = text
        self.placeholder = placeholder
        self.autoFocus = autoFocus
        self.secure = secure
        self.selectAll = selectAll
        self.id = id
        self.submit = submit
    }

    var body: some View {
        let look = ExplorerLook.current
        return TextField(
            text: text,
            placeholder: placeholder,
            font: explorerFonts?.body,
            autoFocus: autoFocus,
            selectionOnFocus: selectAll ? .all : .none,
            secure: secure,
            onSubmit: submit
        )
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
        .background(look.well)
        .border(look.divider)
        .cornerRadius(12)
        .agentId(id)
    }
}

/// The answers, at the right, after a gap.
private struct DialogButtons<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HStack(padding: 0, alignment: .center, spacing: 8) {
            Spacer()
            content
        }
        .padding(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0))
    }
}

/// An answer: a pill, solid accent for the expected one.
struct DialogButton: View {
    let title: String
    var prominent = false
    let id: String
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, id: String,
         action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.id = id
        self.action = action
    }

    var body: some View {
        let look = ExplorerLook.current
        return Text(title, color: prominent ? look.onAccent : look.accent800,
                    font: explorerFonts?.statusSemi,
                    hoverFill: prominent ? look.accentHover : look.accent200,
                    onClick: action)
            .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .background(prominent ? look.accent : look.card)
            .border(prominent ? look.accent : look.accent300)
            .cornerRadius(15)
            .cursor(.pointer)
            .agentId(id)
    }
}

/// The dialogs' glyphs beyond the explorer's own.
enum DialogGlyphs {
    static let copy = "M8 8h12v12H8zM16 8V4H4v12h4"
    static let server = ExplorerGlyphs.server
    static let person = "M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z"
    static let delete = "M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v6M14 11v6"
    static let archive = "M21 8v13H3V8M1 3h22v5H1zM10 12h4"
    static let lock = "M5 11h14v10H5zM8 11V7a4 4 0 0 1 8 0v4"
}
