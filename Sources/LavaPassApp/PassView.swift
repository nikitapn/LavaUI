import Foundation
import LavaPassCore
import LavaUI

struct PassView: View {
    @Bindable var session: PassSession
    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            toolbar
            if let vault = session.snapshot {
                if let reason = vault.readOnlyReason {
                    HStack(padding: 10, alignment: .center, spacing: 10) {
                        Text(reason, color: Theme.current.textSecondary).flexShrink(1)
                        Spacer()
                        if vault.canSaveCopy {
                            Button("Save KDBX 4 Copy", isEnabled: !session.busy) { session.saveCopy() }
                        }
                    }
                    .background(Theme.current.panel)
                }
                HSplitView(initialFraction: 0.2, minLeading: 150, minTrailing: 560) {
                    sidebar(vault)
                } trailing: {
                    HSplitView(initialFraction: 0.43, minLeading: 220, minTrailing: 320) {
                        entryList
                    } trailing: {
                        details
                    }
                }
            } else {
                unlockScreen
            }
            HStack(padding: 10, alignment: .center, spacing: 10) {
                Text(session.busy ? "Working…" : (session.notice ?? (session.snapshot == nil ? "Vault locked" : "Changes save directly to your encrypted vault")),
                     color: Theme.current.textDim, lineLimit: 2)
                    .flexShrink(1)
                Spacer()
                if let vault = session.snapshot {
                    Text("\(vault.entries.filter { !$0.recycled }.count) entries", color: Theme.current.textDim)
                }
            }
            .background(Theme.current.panel)
        }
        .background(Theme.current.background)
        .onAnyPress { _ in session.activity() }
    }

    private var toolbar: some View {
        HStack(height: .pt(48), padding: 8, alignment: .center, spacing: 8) {
            if WindowBridge.drawsOwnChrome { WindowControls(beforeClose: { session.lock() }) }
            VaultMark(size: 24, color: Theme.current.accent)
            Text(session.isDemo ? "Vault · Demo" : "Vault", color: Theme.current.textPrimary)
            if let vault = session.snapshot {
                Text("/  \(vault.name)", color: Theme.current.textDim, lineLimit: 1).flexShrink(1)
            }
            Spacer()
            Button("Open…", isEnabled: !session.busy && !session.isDemo) { session.chooseVault() }
                .agentId("open-vault")
            if session.snapshot != nil {
                Button("New Entry", isEnabled: session.writable && session.draft == nil) { session.newEntry() }
                    .agentId("new-entry")
                Button("Lock") { session.lock() }
                    .agentId("lock-vault")
            }
        }
        .background(Theme.current.panel)
        .windowDrag()
    }

    private var unlockScreen: some View {
        ScrollView(.vertical) {
            VStack(flexGrow: 1, padding: 24, alignment: .center, spacing: 16) {
                Spacer()
                Text(session.creating ? "Create an encrypted vault" : "Your passwords. Your vault.", color: Theme.current.textPrimary)
                Text("KeePass-compatible KDBX files, on your own disk", color: Theme.current.textDim)
                VStack(padding: 0, spacing: 10) {
                    if !session.creating && !session.recentVaults.isEmpty {
                        HStack(padding: 0, alignment: .center, spacing: 8) {
                            Text("Most Recent", color: Theme.current.textSecondary)
                            Spacer()
                            Button("Clear", isEnabled: !session.busy) { session.clearRecentVaults() }
                        }
                        ScrollView(.vertical, showsIndicator: false) {
                            VStack(padding: 0, spacing: 4) {
                                ForEach(Array(session.recentVaults.enumerated()), id: \.offset) { item in
                                    let path = item.element
                                    HStack(padding: 8, alignment: .center, spacing: 8,
                                           onClick: { session.openRecentVault(path) }) {
                                        VStack(padding: 0, spacing: 2) {
                                            Text((path as NSString).lastPathComponent, color: Theme.current.textPrimary, lineLimit: 1)
                                            Text((path as NSString).deletingLastPathComponent, color: Theme.current.textDim, lineLimit: 1)
                                        }
                                    }
                                    .background(session.vaultPath == path ? Theme.current.selectionFill : Color.clear)
                                    .hoverBackground(Theme.current.hover)
                                    .cornerRadius(6)
                                    .cursor(.pointer)
                                    .agentId("recent-vault-\(item.offset)")
                                }
                            }
                        }
                        .frame(height: .pt(Float(min(session.recentVaults.count, 2)) * 64))
                    }
                    Text("Vault", color: Theme.current.textSecondary)
                    TextField(text: $session.vaultPath, placeholder: "Choose an existing .kdbx file")
                        .agentId("vault-path")
                    if !session.creating {
                        HStack(padding: 0, alignment: .center, spacing: 8) {
                            Button("Key File…", isEnabled: !session.busy && !session.isDemo) { session.chooseKeyFile() }
                            Text(session.keyFilePath.isEmpty ? "Optional" : (session.keyFilePath as NSString).lastPathComponent,
                                 color: Theme.current.textDim, lineLimit: 1).flexShrink(1)
                            if !session.keyFilePath.isEmpty {
                                Button("Clear", isEnabled: !session.busy) { session.keyFilePath = "" }
                            }
                        }
                    }
                    Text("Master password", color: Theme.current.textSecondary)
                    TextField(text: $session.masterPassword, placeholder: "Master password", secure: true,
                              onSubmit: { session.unlock() })
                        .agentId("master-password")
                    if session.creating {
                        TextField(text: $session.confirmation, placeholder: "Confirm master password", secure: true,
                                  onSubmit: { session.unlock() })
                            .agentId("master-confirmation")
                    }
                    Toggle("Remember master password in desktop keyring", isOn: $session.rememberMaster, isEnabled: !session.isDemo && !session.busy)
                    HStack(padding: 0, alignment: .center, spacing: 8) {
                        Button("New Vault…", isEnabled: !session.busy && !session.isDemo) { session.newVault() }
                        Spacer()
                        if !session.creating {
                            Button("Use Keyring", isEnabled: !session.busy && !session.vaultPath.isEmpty && !session.isDemo) {
                                session.unlock(fromKeyring: true)
                            }
                            .agentId("keyring-unlock")
                        }
                        Button(session.creating ? "Create Vault" : "Unlock", isEnabled: !session.busy && !session.vaultPath.isEmpty) {
                            session.unlock()
                        }
                        .agentId("unlock-vault")
                    }
                    if !session.creating && !session.vaultPath.isEmpty {
                        Button("Forget Remembered Password", isEnabled: !session.busy && !session.isDemo) { session.forgetMaster() }
                    }
                }
                .frame(width: .pt(550))
                Spacer()
                Text("Locks after 5 minutes of inactivity. Copied passwords clear after 30 seconds.", color: Theme.current.textDim)
            }
        }
    }

    private func sidebar(_ vault: VaultSnapshot) -> some View {
        VStack(flexGrow: 1, padding: 8, spacing: 6) {
            Text("GROUPS", color: Theme.current.textDim).padding(8)
            HStack(padding: 10, alignment: .center, onClick: { session.selectGroup(nil) }) {
                Text("All Entries", color: Theme.current.textPrimary)
            }
            .background(session.selectedGroup == nil ? Theme.current.selectionFill : Color.clear)
            .hoverBackground(Theme.current.hover)
            .cornerRadius(5)
            .agentId("all-entries")
            ScrollView(.vertical) {
                VStack(padding: 0, spacing: 2) {
                    ForEach(vault.groups) { group in
                        HStack(padding: 0, alignment: .center, spacing: 8,
                               onClick: { session.selectGroup(group.id) }) {
                            VaultMark(size: 16, color: Theme.current.textDim)
                            Text(group.name, color: Theme.current.textSecondary, lineLimit: 1).flexShrink(1)
                            Spacer()
                        }
                        .padding(EdgeInsets(top: 9, leading: Float(10 + group.depth * 12), bottom: 9, trailing: 6))
                        .background(session.selectedGroup == group.id ? Theme.current.selectionFill : Color.clear)
                        .hoverBackground(Theme.current.hover)
                        .cornerRadius(5)
                        .cursor(.pointer)
                        .agentId("group-\(group.id)")
                    }
                }
            }
            if session.groupName != nil {
                TextField(text: Binding(get: { session.groupName ?? "" }, set: { session.groupName = $0 }),
                          placeholder: "Group name", autoFocus: true, onSubmit: { session.addGroup() })
                    .agentId("group-name")
                HStack(padding: 0, spacing: 6) {
                    Button("Cancel") { session.groupName = nil }
                    Button("Add", isEnabled: session.writable) { session.addGroup() }
                }
            } else {
                Button("New Group", isEnabled: session.writable && session.draft == nil) { session.groupName = "" }
                    .agentId("new-group")
            }
        }
        .background(Theme.current.panel)
    }

    private var entryList: some View {
        VStack(flexGrow: 1, padding: 8, spacing: 8) {
            TextField(text: $session.search, placeholder: "Search entries…")
                .agentId("search-entries")
            ScrollView(.vertical) {
                VStack(padding: 0, spacing: 3) {
                    ForEach(session.visibleEntries) { entry in
                        VStack(padding: 10, spacing: 4, onClick: { session.selectEntry(entry.id) }) {
                            Text(entry.title.isEmpty ? "Untitled" : entry.title,
                                 color: Theme.current.textPrimary, lineLimit: 1)
                            Text(entry.username.isEmpty ? entry.group : entry.username,
                                 color: Theme.current.textDim, lineLimit: 1)
                        }
                        .background(session.selectedEntry == entry.id ? Theme.current.selectionFill : Color.clear)
                        .hoverBackground(Theme.current.hover)
                        .cornerRadius(6)
                        .cursor(.pointer)
                        .agentId("entry-\(entry.id)")
                    }
                    if session.visibleEntries.isEmpty {
                        Text(session.search.isEmpty ? "No entries yet" : "No matching entries", color: Theme.current.textDim)
                            .padding(16)
                    }
                }
            }
        }
    }

    @ViewBuilder private var details: some View {
        if session.draft != nil {
            VStack(flexGrow: 1, padding: 0, spacing: 0) {
                ScrollView(.vertical) {
                    VStack(padding: 20, spacing: 10) {
                        Text(session.draft?.id == nil ? "New Entry" : "Edit Entry", color: Theme.current.textPrimary)
                        field("Title", key: \.title, id: "entry-title")
                        field("Username", key: \.username, id: "entry-username")
                        Text("Password", color: Theme.current.textDim)
                        TextField(text: draftBinding(\.password), placeholder: "Password", secure: !session.showPassword)
                            .agentId("entry-password")
                        HStack(padding: 0, alignment: .center, spacing: 6) {
                            Button(session.showPassword ? "Hide" : "Reveal") { session.showPassword.toggle() }
                            Button("Generate", isEnabled: !session.busy) { session.generatePassword() }
                                .agentId("generate-password")
                            Button("−") { session.generatedLength = max(12, session.generatedLength - 4) }
                            Text("\(session.generatedLength)", color: Theme.current.textDim)
                            Button("+") { session.generatedLength = min(64, session.generatedLength + 4) }
                        }
                        field("URL", key: \.url, id: "entry-url")
                        Text("Notes", color: Theme.current.textDim)
                        EditorView(text: draftBinding(\.notes), showLineNumbers: false, wraps: true, visibleLines: 8)
                            .frame(height: .pt(180))
                            .agentId("entry-notes")
                        Text("Group", color: Theme.current.textDim)
                        ForEach((session.snapshot?.groups ?? []).filter { !$0.recycleBin }) { group in
                            HStack(padding: 6, alignment: .center, spacing: 8,
                                   onClick: { session.draft?.groupID = group.id }) {
                                Text(session.draft?.groupID == group.id ? "●" : "○", color: Theme.current.textDim)
                                Text(group.name, color: Theme.current.textSecondary, lineLimit: 1)
                            }
                            .hoverBackground(Theme.current.hover)
                            .cornerRadius(4)
                        }
                    }
                }
                HStack(padding: 16, alignment: .center, spacing: 8) {
                    Button("Cancel", isEnabled: !session.busy) { session.draft = nil; session.showPassword = false }
                    Spacer()
                    Button("Save Entry", isEnabled: session.writable) { session.saveEntry() }
                        .agentId("save-entry")
                }
                .background(Theme.current.panel)
            }
        } else if let entry = session.selected {
            entryDetails(entry)
        } else {
            VStack(flexGrow: 1, padding: 24, alignment: .center, spacing: 14) {
                Spacer()
                Text("Select an entry", color: Theme.current.textSecondary)
                Text("Copy a password, or edit its details", color: Theme.current.textDim)
                Button("New Entry", isEnabled: session.writable) { session.newEntry() }
                Spacer()
            }
        }
    }

    private func entryDetails(_ entry: VaultEntry) -> some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            ScrollView(.vertical) {
                VStack(padding: 20, spacing: 14) {
                    Text(entry.title, color: Theme.current.textPrimary)
                    Text(entry.group, color: Theme.current.textDim, lineLimit: 2)
                    Divider()
                    Text("Username", color: Theme.current.textDim)
                    Text(entry.username.isEmpty ? "—" : entry.username, color: Theme.current.textPrimary)
                    HStack(padding: 0, alignment: .center, spacing: 8) {
                        Button("Copy Username", isEnabled: !entry.username.isEmpty && !session.busy) { session.copyField(entry.username) }
                        Button("Copy Password", isEnabled: !session.busy) { session.copyPassword() }
                            .agentId("copy-password")
                    }
                    Text("Password", color: Theme.current.textDim)
                    Text("••••••••••••", color: Theme.current.textPrimary)
                    if !entry.url.isEmpty {
                        Text("URL", color: Theme.current.textDim)
                        Text(entry.url, color: Theme.current.textSecondary)
                        Button("Copy URL", isEnabled: !session.busy) { session.copyField(entry.url) }
                    }
                    Divider()
                    Text("Notes", color: Theme.current.textDim)
                    if let content = session.entryContent, content.entryID == entry.id {
                        Text(content.notes.isEmpty ? "No notes" : content.notes,
                             color: content.notes.isEmpty ? Theme.current.textDim : Theme.current.textPrimary)
                            .agentId("entry-notes-display")
                        if !content.notes.isEmpty {
                            Button("Copy Notes", isEnabled: !session.busy) { session.copyField(content.notes) }
                                .agentId("copy-notes")
                        }
                        Divider()
                        HStack(padding: 0, alignment: .center, spacing: 8) {
                            Text("Attachments (\(content.attachments.count))", color: Theme.current.textDim)
                            Spacer()
                            Button("Add File…", isEnabled: session.writable) { session.addAttachment() }
                                .agentId("add-attachment")
                        }
                        ForEach(content.attachments) { attachment in
                            attachmentRow(attachment)
                        }
                        if content.attachments.isEmpty {
                            Text("No attachments", color: Theme.current.textDim)
                        }
                    } else {
                        Text("Loading entry…", color: Theme.current.textDim)
                    }
                    if entry.customFieldCount > 0 {
                        Text("\(entry.customFieldCount) custom fields preserved", color: Theme.current.textDim)
                    }
                }
            }
            VStack(padding: 16, spacing: 8) {
                if session.confirmRecycle {
                    Text("Move this entry to the Recycle Bin?", color: Theme.current.textSecondary)
                    HStack(padding: 0, spacing: 8) {
                        Button("Cancel") { session.confirmRecycle = false }
                        Button("Move to Bin", isEnabled: session.writable) { session.recycleEntry() }
                    }
                } else {
                    HStack(padding: 0, alignment: .center, spacing: 8) {
                        Button(entry.recycled ? "Edit / Restore" : "Edit", isEnabled: session.writable) { session.editEntry() }
                            .agentId("edit-entry")
                        if !entry.recycled {
                            Button("Recycle", isEnabled: session.writable) { session.confirmRecycle = true }
                        }
                        Spacer()
                    }
                }
            }
            .background(Theme.current.panel)
        }
    }

    private func attachmentRow(_ attachment: VaultAttachment) -> some View {
        VStack(padding: 10, spacing: 8) {
            Text(attachment.name, color: Theme.current.textPrimary)
                .agentId("attachment-name-\(attachment.id)")
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file),
                 color: Theme.current.textDim)
            HStack(padding: 0, alignment: .center, spacing: 6) {
                Button("Open", isEnabled: !session.busy) { session.openAttachment(attachment) }
                    .tooltip("Open a private temporary copy; removed when the vault locks")
                    .agentId("open-attachment-\(attachment.id)")
                Button("Save As…", isEnabled: !session.busy) { session.saveAttachment(attachment) }
                    .agentId("save-attachment-\(attachment.id)")
                Spacer()
                Button("Remove", isEnabled: session.writable) { session.attachmentPendingRemoval = attachment }
                    .agentId("remove-attachment-\(attachment.id)")
            }
            if session.attachmentPendingRemoval?.id == attachment.id {
                Text("Remove this attachment? The previous copy remains in entry history.", color: Theme.current.textSecondary)
                HStack(padding: 0, alignment: .center, spacing: 6) {
                    Button("Cancel") { session.attachmentPendingRemoval = nil }
                    Spacer()
                    Button("Remove Attachment", isEnabled: session.writable) { session.removeAttachment() }
                        .agentId("confirm-remove-attachment")
                }
            }
        }
        .background(Theme.current.inset)
        .cornerRadius(6)
    }

    private func draftBinding(_ key: WritableKeyPath<CredentialDraft, String>) -> Binding<String> {
        Binding(get: { session.draft?[keyPath: key] ?? "" }, set: { session.draft?[keyPath: key] = $0 })
    }
    private func field(_ label: String, key: WritableKeyPath<CredentialDraft, String>, id: String) -> some View {
        VStack(padding: 0, spacing: 6) {
            Text(label, color: Theme.current.textDim)
            TextField(text: draftBinding(key), placeholder: label).agentId(id)
        }
    }
}

private struct VaultMark: View {
    var size: Float
    var color: Color
    var body: some View {
        Canvas(label: "Vault", width: .pt(size), height: .pt(size)) { list, frame in
            let u = size / 24
            list.strokedRect(x: frame.x + 3 * u, y: frame.y + 10 * u,
                             w: 18 * u, h: 12 * u, color: color, radius: 2 * u, width: 1.5 * u)
            list.line(x1: frame.x + 7 * u, y1: frame.y + 10 * u,
                      x2: frame.x + 7 * u, y2: frame.y + 6 * u, color: color, width: 1.5 * u)
            list.line(x1: frame.x + 7 * u, y1: frame.y + 6 * u,
                      x2: frame.x + 17 * u, y2: frame.y + 6 * u, color: color, width: 1.5 * u)
            list.line(x1: frame.x + 17 * u, y1: frame.y + 6 * u,
                      x2: frame.x + 17 * u, y2: frame.y + 10 * u, color: color, width: 1.5 * u)
            list.circle(cx: frame.x + 12 * u, cy: frame.y + 15 * u, radius: 1.5 * u, color: color)
            list.line(x1: frame.x + 12 * u, y1: frame.y + 15 * u,
                      x2: frame.x + 12 * u, y2: frame.y + 18 * u, color: color, width: 1.5 * u)
        }
    }
}
