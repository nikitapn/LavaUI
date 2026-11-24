import Foundation
import LavaPassCore
import LavaUI

struct PassView: View {
    @Bindable var session: PassSession
    let fonts: PassFonts

    @ViewBuilder var body: some View {
        if let font = fonts.body { vaultWindow.font(font) }
        else { vaultWindow }
    }

    private var vaultWindow: some View {
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
                HSplitView(initialFraction: 0.196, minLeading: 164, minTrailing: 640) {
                    sidebar(vault)
                } trailing: {
                    HSplitView(initialFraction: 0.333, minLeading: 220, minTrailing: 320) {
                        entryList
                    } trailing: {
                        details
                    }
                }
            } else {
                unlockScreen
            }
            HStack(height: .pt(34), padding: 0, alignment: .center, spacing: 10) {
                statusDot(session.snapshot == nil ? PassLook.accent : PassLook.sage)
                Text(session.busy ? "Working…" : (session.notice ?? (session.snapshot == nil
                    ? "Vault locked" : "Changes save directly to your encrypted vault")),
                     color: PassLook.soft, font: fonts.caption, lineLimit: 1)
                    .flexShrink(1)
                Spacer()
                if let vault = session.snapshot {
                    Text("\(vault.entries.filter { !$0.recycled }.count) entries", color: PassLook.soft, font: fonts.caption)
                } else {
                    Text("KeePass · KDBX", color: PassLook.soft, font: fonts.caption)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 18))
            .background(PassLook.surface)
        }
        .background(PassLook.card)
        .onAnyPress { _ in session.activity() }
    }

    private var toolbar: some View {
        HStack(height: .pt(50), padding: 0, alignment: .center, spacing: 12) {
            if WindowBridge.drawsOwnChrome {
                WindowControls(style: WindowControlsStyle(
                    size: 13, close: PassLook.accent, minimize: Color(rgb24: 0xf6_a0_6b),
                    maximize: PassLook.sage
                ), beforeClose: { session.lock() })
            }
            Text(session.isDemo ? "Vault · Demo" : "Vault", color: PassLook.text, font: fonts.strong)
            if let vault = session.snapshot {
                PassIcon(symbol: "chevron", color: PassLook.muted, size: 12)
                Text(vault.name, color: PassLook.soft, lineLimit: 1).flexShrink(1)
                Text("Unlocked", color: PassLook.sageInk, font: fonts.caption)
                    .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .background(PassLook.sagePale)
                    .cornerRadius(14)
            }
            Spacer()
            action("Open vault", id: "open-vault", icon: "folder", style: .icon,
                   enabled: !session.busy && !session.isDemo) { session.chooseVault() }
            if session.snapshot != nil {
                action("New entry", id: "new-entry", icon: "plus", style: .icon,
                       enabled: session.writable && session.draft == nil) { session.newEntry() }
                action("Lock", id: "lock-vault", icon: "lock", style: .warm, height: 30) { session.lock() }
            }
        }
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
        .background(PassLook.surface)
        .windowDrag()
    }

    private var unlockScreen: some View {
        ScrollView(.vertical) {
            VStack(padding: 0, alignment: .center, spacing: 18) {
                VStack(padding: 0, alignment: .center, spacing: 7) {
                    HStack(width: .pt(64), height: .pt(64), padding: 0, alignment: .center) {
                        Spacer()
                        PassIcon(symbol: "shield", color: PassLook.orange, size: 30)
                        Spacer()
                    }
                    .background(PassLook.peach)
                    .cornerRadius(22)
                    Text(session.creating ? "Create an encrypted vault" : "Your passwords. Your vault.",
                         color: PassLook.text, font: fonts.hero, align: .center)
                    Text("KeePass-compatible. Encrypted and stored on your disk.", color: PassLook.soft)
                }
                HStack(width: .pt(840), padding: 0, alignment: .start, spacing: 20) {
                    if session.creating { Spacer() }
                    else { recentVaults.frame(width: .pt(328)) }
                    unlockForm.frame(width: .pt(492))
                    if session.creating { Spacer() }
                }
                HStack(padding: 0, alignment: .center, spacing: 7) {
                    PassIcon(symbol: "clock", color: PassLook.muted, size: 14)
                    Text("Locks after 5 minutes of inactivity. Copied passwords clear after 30 seconds.",
                         color: PassLook.soft, font: fonts.caption)
                }
            }
            .padding(EdgeInsets(top: 24, leading: 0, bottom: 16, trailing: 0))
        }
        .agentId("unlock-scroll")
    }

    private var recentVaults: some View {
        VStack(padding: 0, spacing: 6) {
            HStack(padding: 0, alignment: .center, spacing: 8) {
                kicker("Recent vaults")
                Spacer()
                if !session.recentVaults.isEmpty {
                    action("Clear list", id: "clear-recent-vaults", style: .ghost, height: 26,
                           enabled: !session.busy) { session.clearRecentVaults() }
                }
            }
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 4))
            if session.recentVaults.isEmpty {
                Text("No recent vaults. Open a .kdbx file to start.", color: PassLook.soft,
                     font: fonts.caption, align: .center)
                    .padding(14)
                    .frame(width: .pct(100), height: .pt(60))
                    .border(PassLook.faint)
                    .cornerRadius(18)
            }
            ForEach(Array(session.recentVaults.enumerated()), id: \.element) { item in
                let path = item.element
                let selected = session.vaultPath == path
                HStack(height: .pt(58), padding: 0, alignment: .center, spacing: 2) {
                    HStack(padding: 10, alignment: .center, spacing: 12,
                           onClick: { if !session.busy { session.openRecentVault(path) } }) {
                        iconTile("vault", size: 38, color: selected ? PassLook.orange : PassLook.sageInk,
                                 fill: selected ? PassLook.peachHover : PassLook.sagePale)
                        VStack(padding: 0, spacing: 2) {
                            Text((path as NSString).lastPathComponent, color: PassLook.text,
                                 font: fonts.strong, lineLimit: 1)
                            Text((path as NSString).deletingLastPathComponent, color: PassLook.soft,
                                 font: fonts.caption, lineLimit: 1)
                        }
                        .flexShrink(1)
                        Spacer()
                    }
                    .flexGrow(1).flexShrink(1)
                    .hoverBackground(selected ? PassLook.peachHover : PassLook.well)
                    .cornerRadius(18)
                    .cursor(.pointer)
                    .agentId("recent-vault-\(item.offset)")
                    action("Remove from recent vaults", id: "remove-recent-vault-\(item.offset)", icon: "close",
                           style: .icon, enabled: !session.busy) { session.removeRecentVault(path) }
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 6))
                }
                .background(selected ? PassLook.peach : PassLook.surface)
                .cornerRadius(18)
            }
            HStack(padding: 0, alignment: .center) {
                action("New vault…", id: "create-vault", icon: "plus", style: .ghost,
                       enabled: !session.busy && !session.isDemo) { session.newVault() }
                Spacer()
            }
        }
    }

    private var unlockForm: some View {
        VStack(padding: 20, spacing: 10) {
            Text(session.creating ? "New vault" : "Unlock your vault",
                 color: PassLook.text, font: fonts.heading)
            labeled("Vault file") {
                inputPill("file", focused: session.vaultPathFocused) {
                    TextField(text: $session.vaultPath, placeholder: "Choose a .kdbx file",
                              focusRing: FocusRingStyle.none, restingOutline: false)
                        .flexGrow(1).flexShrink(1)
                        .focused($session.vaultPathFocused)
                        .agentId("vault-path")
                    action("Browse…", id: "browse-vault", height: 30,
                           enabled: !session.busy && !session.isDemo) { session.chooseVault() }
                }
            }
            if !session.creating {
                labeled("Key file · optional") {
                    inputPill("key") {
                        Text(session.keyFilePath.isEmpty ? "No key file" : session.keyFilePath,
                             color: session.keyFilePath.isEmpty ? PassLook.muted : PassLook.text,
                             lineLimit: 1)
                            .flexGrow(1).flexShrink(1)
                        if !session.keyFilePath.isEmpty {
                            action("Remove key file", id: "remove-key-file", icon: "close", style: .icon,
                                   enabled: !session.busy) { session.keyFilePath = "" }
                        }
                        action("Choose…", id: "choose-key-file", height: 30,
                               enabled: !session.busy && !session.isDemo) { session.chooseKeyFile() }
                    }
                }
            }
            labeled("Master password") {
                inputPill("lock", focused: session.masterPasswordFocused, error: session.unlockError != nil) {
                    TextField(text: $session.masterPassword, placeholder: "Enter master password",
                              autoFocus: true, focusRing: FocusRingStyle.none,
                              restingOutline: false,
                              secure: !session.showMasterPassword, onSubmit: { session.unlock() })
                        .flexGrow(1).flexShrink(1)
                        .focused($session.masterPasswordFocused)
                        .agentId("master-password")
                    action(session.showMasterPassword ? "Hide password" : "Show password",
                           id: "reveal-master-password", icon: session.showMasterPassword ? "eye-off" : "eye",
                           style: .icon, enabled: !session.busy) { session.toggleMasterPasswordVisibility() }
                }
                Text(session.unlockError ?? "", color: PassLook.brown, font: fonts.caption, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 4))
                    .frame(height: .pt(18))
                    .agentId("unlock-error")
            }
            if session.creating {
                labeled("Confirm master password") {
                    inputPill("lock", focused: session.confirmationFocused) {
                        TextField(text: $session.confirmation, placeholder: "Repeat master password",
                                  focusRing: FocusRingStyle.none, restingOutline: false, secure: true,
                                  onSubmit: { session.unlock() })
                            .flexGrow(1).flexShrink(1)
                            .focused($session.confirmationFocused)
                            .agentId("master-confirmation")
                    }
                }
            }
            Toggle("Remember in desktop keyring", isOn: $session.rememberMaster,
                   style: ToggleStyle(trackWidth: 42, trackHeight: 24, knobInset: 3,
                                      offTrack: PassLook.faint, onTrack: PassLook.sage, knob: .white,
                                      disabledTrack: PassLook.faint, disabledKnob: PassLook.card,
                                      labelGap: 12, duration: 0.15),
                   isEnabled: !session.isDemo && !session.busy)
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Spacer()
                if !session.creating {
                    action("Use keyring", id: "keyring-unlock", icon: "key",
                           enabled: !session.busy && !session.vaultPath.isEmpty && !session.isDemo) {
                        session.unlock(fromKeyring: true)
                    }
                }
                action(session.creating ? "Create vault" : "Unlock", id: "unlock-vault", icon: "lock",
                       style: .primary, enabled: !session.busy && !session.vaultPath.isEmpty) {
                    session.unlock()
                }
            }
            if !session.creating {
                Divider()
                HStack(padding: 0, alignment: .center, spacing: 10) {
                    statusDot(PassLook.muted)
                    Text("Desktop keyring", color: PassLook.soft, font: fonts.caption)
                    Spacer()
                    action("Forget", id: "forget-password", style: .ghost, height: 26,
                           enabled: !session.busy && !session.vaultPath.isEmpty && !session.isDemo) {
                        session.forgetMaster()
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0))
            }
        }
        .background(PassLook.surface)
        .cornerRadius(28)
        .underlay {
            Canvas(width: .pct(100), height: .pct(100)) { list, box in
                list.shadow(x: box.x, y: box.y, w: box.w, h: box.h,
                            cornerRadius: 28, blur: 3, color: PassLook.text.opacity(0.14), offsetY: 1)
            }
        }
        .shake(trigger: session.unlockShake)
        .agentId("unlock-card")
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(padding: 0, spacing: 4) {
            Text(label, color: PassLook.soft, font: fonts.strong)
                .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
            content()
        }
    }

    private func inputPill<Content: View>(
        _ icon: String, focused: Bool = false, error: Bool = false, fill: Color = PassLook.card,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(height: .pt(40), padding: 0, alignment: .center, spacing: 6) {
            PassIcon(symbol: icon, color: PassLook.muted, size: 15)
            content()
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 6))
        .background(fill)
        .border(error ? PassLook.orange : focused ? PassLook.accent : PassLook.divider,
                width: error || focused ? 1.5 : 1)
        .cornerRadius(20)
    }

    private enum ActionStyle { case plain, primary, ghost, icon, warm }

    private func action(_ title: String, id: String, icon: String? = nil,
                        style: ActionStyle = .plain, height: Float = 36,
                        enabled: Bool = true, run: @escaping () -> Void) -> some View {
        let ink = !enabled ? PassLook.muted : style == .primary ? PassLook.card
            : style == .ghost || style == .warm ? PassLook.orange : PassLook.text
        let fill: Color = switch style {
        case .primary: enabled ? PassLook.orange : PassLook.faint
        case .plain: PassLook.card
        case .warm: PassLook.peach
        case .ghost, .icon: .clear
        }
        let hover = style == .primary ? PassLook.brown
            : style == .warm ? PassLook.peachHover : PassLook.well
        let h: Float = style == .icon ? 30 : height
        let inset: Float = style == .icon ? 0 : style == .primary ? 18 : 12
        return HStack(width: style == .icon ? .pt(h) : .auto, height: .pt(h), padding: 0,
                      alignment: .center, spacing: 7, onClick: enabled ? run : nil) {
            if style == .icon { Spacer() }
            if let icon { PassIcon(symbol: icon, color: ink, size: style == .icon ? 16 : 14) }
            if style != .icon { Text(title, color: ink, font: fonts.strong).flexShrink(0) }
            if style == .icon { Spacer() }
        }
        .padding(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
        .background(fill)
        .border(style == .plain ? PassLook.divider : .clear)
        .hoverBackground(enabled ? hover : .clear)
        .cornerRadius(h / 2)
        .cursor(enabled ? .pointer : .arrow)
        .tooltip(title)
        .agentId(id)
    }

    private func kicker(_ title: String) -> some View {
        Text(title.uppercased(), color: PassLook.muted, font: fonts.kicker)
    }

    private func statusDot(_ color: Color) -> some View {
        Canvas(width: .pt(8), height: .pt(8)) { list, box in
            list.circle(cx: box.x + 4, cy: box.y + 4, radius: 4, color: color)
        }
    }

    private func iconTile(_ symbol: String, size: Float, color: Color, fill: Color) -> some View {
        HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center, spacing: 0) {
            Spacer()
            PassIcon(symbol: symbol, color: color, size: 17)
            Spacer()
        }
        .background(fill)
        .cornerRadius(size / 3)
    }

    private func sidebar(_ vault: VaultSnapshot) -> some View {
        let counts = Dictionary(grouping: vault.entries, by: \.groupID).mapValues(\.count)
        let activeCount = vault.entries.filter { !$0.recycled }.count
        return VStack(flexGrow: 1, padding: 10, spacing: 6) {
            kicker("Groups").padding(8)
            ScrollView(.vertical) {
                VStack(padding: 0, spacing: 2) {
                    groupRow("All Entries", id: "all-entries", icon: "list",
                             count: activeCount, selected: session.selectedGroup == nil) {
                        session.selectGroup(nil)
                    }
                    ForEach(vault.groups) { group in
                        groupRow(group.name, id: "group-\(group.id)", icon: group.recycleBin ? "trash" : "folder",
                                 count: counts[group.id, default: 0], selected: session.selectedGroup == group.id,
                                 indent: Float(min(group.depth, 5) * 10)) {
                            session.selectGroup(group.id)
                        }
                    }
                }
            }
            if session.groupName != nil {
                TextField(text: Binding(get: { session.groupName ?? "" }, set: { session.groupName = $0 }),
                          placeholder: "Group name", autoFocus: true, onSubmit: { session.addGroup() })
                    .agentId("group-name")
                HStack(padding: 0, alignment: .center, spacing: 6) {
                    action("Cancel", id: "cancel-group", style: .ghost) { session.groupName = nil }
                    Spacer()
                    action("Add", id: "add-group", style: .primary, enabled: session.writable) { session.addGroup() }
                }
            } else {
                HStack(padding: 0, alignment: .center) {
                    Spacer()
                    action("New group", id: "new-group", icon: "plus",
                           enabled: session.writable && session.draft == nil) { session.groupName = "" }
                    Spacer()
                }
            }
        }
        .background(PassLook.surface)
    }

    private func groupRow(_ title: String, id: String, icon: String, count: Int?,
                          selected: Bool, indent: Float = 0, run: @escaping () -> Void) -> some View {
        HStack(height: .pt(34), padding: 0, alignment: .center, spacing: 9, onClick: run) {
            PassIcon(symbol: icon, color: selected ? PassLook.orange : PassLook.soft, size: 15)
            Text(title, color: selected ? PassLook.brown : PassLook.text, font: fonts.strong, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if let count { Text(String(count), color: PassLook.soft, font: fonts.caption) }
        }
        .padding(EdgeInsets(top: 0, leading: 12 + indent, bottom: 0, trailing: 12))
        .background(selected ? PassLook.peach : .clear)
        .hoverBackground(selected ? PassLook.peachHover : PassLook.well)
        .cornerRadius(17)
        .cursor(.pointer)
        .agentId(id)
    }

    private var entryList: some View {
        VStack(flexGrow: 1, padding: 10, spacing: 8) {
            inputPill("search", focused: session.searchFocused, fill: PassLook.well) {
                TextField(text: $session.search, placeholder: "Search entries",
                          focusRing: FocusRingStyle.none, restingOutline: false)
                    .background(.clear)
                    .flexGrow(1)
                    .focused($session.searchFocused)
                    .agentId("search-entries")
                Text("Ctrl+F", color: PassLook.soft, font: fonts.caption)
                    .padding(5)
                    .background(PassLook.card)
                    .cornerRadius(10)
            }
            ScrollView(.vertical) {
                VStack(padding: 0, spacing: 2) {
                    ForEach(session.visibleEntries) { entry in
                        entryRow(entry)
                    }
                    if session.visibleEntries.isEmpty {
                        Text(session.search.isEmpty ? "No entries yet" : "No matching entries",
                             color: PassLook.soft, align: .center)
                            .padding(16)
                    }
                }
            }
        }
        .background(PassLook.card)
    }

    private func entryRow(_ entry: VaultEntry) -> some View {
        let selected = session.selectedEntry == entry.id
        return HStack(padding: 9, alignment: .center, spacing: 12,
                      onClick: { session.selectEntry(entry.id) }) {
            entryTile(entry, size: 36)
            VStack(padding: 0, spacing: 2) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title,
                     color: selected ? PassLook.brown : PassLook.text, font: fonts.strong, lineLimit: 1)
                Text(entry.username.isEmpty ? entry.group : entry.username, color: PassLook.soft,
                     font: fonts.caption, lineLimit: 1)
            }
            .flexShrink(1)
            Spacer()
        }
        .background(selected ? PassLook.peach : .clear)
        .hoverBackground(selected ? PassLook.peachHover : PassLook.well)
        .cornerRadius(16)
        .cursor(.pointer)
        .agentId("entry-\(entry.id)")
    }

    private func entryTile(_ entry: VaultEntry, size: Float) -> some View {
        let palettes: [(Color, Color)] = [
            (PassLook.peach, PassLook.brown), (PassLook.sagePale, PassLook.sageInk),
            (PassLook.faint, PassLook.soft), (PassLook.orange, PassLook.card)
        ]
        let (fill, ink) = palettes[Int(entry.id.uuid.0) % palettes.count]
        return Text(entry.title.first.map { String($0).uppercased() } ?? "?", color: ink,
                    font: size > 40 ? fonts.detail : fonts.heading, align: .center)
            .frame(width: .pt(size), height: .pt(size))
            .background(fill)
            .cornerRadius(size / 3)
    }

    private var details: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            if session.draft != nil {
                editDetails
            } else if let details = session.entryDetails {
                entryDetails(details)
            } else if session.selectedEntry == nil {
                VStack(flexGrow: 1, padding: 24, alignment: .center, spacing: 8) {
                    Spacer()
                    Text("Nothing selected", color: PassLook.text, font: fonts.heading)
                    Text("Pick an entry on the left, or add a new one.", color: PassLook.soft)
                    Spacer()
                }
            }
            if let message = session.clipboardNotice {
                HStack(padding: 0, alignment: .center) {
                    Spacer()
                    HStack(padding: 0, alignment: .center, spacing: 6) {
                        PassIcon(symbol: "check", color: PassLook.sagePale, size: 14)
                        Text(message, color: PassLook.card, font: fonts.caption, lineLimit: 1)
                            .flexShrink(1)
                        Text("Clear now", color: PassLook.card, font: fonts.strong, hoverFill: PassLook.soft,
                             align: .center, onClick: { session.clearClipboard() })
                            .padding(6)
                            .cornerRadius(14)
                            .cursor(.pointer)
                    }
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 6))
                    .background(PassLook.text)
                    .cornerRadius(18)
                    .agentId("clipboard-toast")
                    Spacer()
                }
                .padding(8)
            }
        }
        .background(PassLook.card)
    }

    private var editDetails: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            ScrollView(.vertical) {
                VStack(padding: 22, spacing: 14) {
                    HStack(padding: 0, alignment: .center, spacing: 8) {
                        Text(session.draft?.id == nil ? "New entry" : "Edit entry",
                             color: PassLook.text, font: fonts.detail)
                        Spacer()
                        Text("Unsaved", color: PassLook.brown, font: fonts.caption)
                            .padding(6).background(PassLook.peach).cornerRadius(12)
                    }
                    field("Title", key: \.title, id: "entry-title")
                    field("Username", key: \.username, id: "entry-username")
                    labeled("Password") {
                        strengthMeter(PasswordStrength(password: session.draft?.password ?? ""))
                        inputPill("lock") {
                            TextField(text: draftBinding(\.password), placeholder: "Password",
                                      focusRing: .rounded, restingOutline: false, secure: !session.showPassword)
                                .flexGrow(1).flexShrink(1)
                                .agentId("entry-password")
                            action(session.showPassword ? "Hide password" : "Show password",
                                   id: "reveal-draft-password", icon: session.showPassword ? "eye-off" : "eye",
                                   style: .icon) { session.showPassword.toggle() }
                        }
                        HStack(padding: 0, alignment: .center, spacing: 6, wraps: true) {
                            action("Generate", id: "generate-password", icon: "key", height: 30,
                                   enabled: !session.busy) { session.generatePassword() }
                            HStack(padding: 0, alignment: .center, spacing: 4) {
                                action("Shorter", id: "password-shorter", icon: "minus", style: .icon,
                                       enabled: session.generatedLength > 12) { session.generatedLength -= 1 }
                                Text("\(session.generatedLength) chars", color: PassLook.text, font: fonts.caption)
                                action("Longer", id: "password-longer", icon: "plus", style: .icon,
                                       enabled: session.generatedLength < 64) { session.generatedLength += 1 }
                            }
                            .background(PassLook.well)
                            .cornerRadius(15)
                            generatorOption("ABC", id: "uppercase", option: .uppercase)
                            generatorOption("abc", id: "lowercase", option: .lowercase)
                            generatorOption("123", id: "numbers", option: .numbers)
                            generatorOption("#$%", id: "symbols", option: .symbols)
                        }
                    }
                    field("Website", key: \.url, id: "entry-url")
                    labeled("Notes") {
                        EditorView(text: draftBinding(\.notes), showLineNumbers: false, wraps: true, visibleLines: 8)
                            .frame(height: .pt(114))
                            .background(PassLook.well)
                            .border(PassLook.divider)
                            .cornerRadius(18)
                            .agentId("entry-notes")
                    }
                    labeled("Group") {
                        ForEach((session.snapshot?.groups ?? []).filter { !$0.recycleBin }) { group in
                            groupRow(group.name, id: "draft-group-\(group.id)", icon: "folder",
                                     count: nil, selected: session.draft?.groupID == group.id,
                                     indent: Float(min(group.depth, 5) * 10)) {
                                session.draft?.groupID = group.id
                            }
                        }
                    }
                }
            }
            Divider()
            HStack(padding: 12, alignment: .center, spacing: 8) {
                Text("Saved to the encrypted vault file.", color: PassLook.soft, font: fonts.caption)
                    .flexShrink(1)
                Spacer()
                action("Cancel", id: "cancel-entry", enabled: !session.busy) {
                    session.draft = nil; session.showPassword = false
                }
                action("Save entry", id: "save-entry", icon: "check", style: .primary, enabled: session.writable) {
                    session.saveEntry()
                }
            }
        }
    }

    private func generatorOption(_ title: String, id: String, option: PasswordGenerator.Characters) -> some View {
        action(title, id: "password-\(id)", style: session.generatedCharacters.contains(option) ? .warm : .plain,
               height: 28) {
            let next = session.generatedCharacters.symmetricDifference(option)
            if !next.isEmpty { session.generatedCharacters = next }
        }
    }

    private func entryDetails(_ details: PassSession.EntryDetails) -> some View {
        let entry = details.entry
        let content = details.content
        return ScrollView(.vertical) {
            VStack(padding: 22, spacing: 10) {
                HStack(padding: 0, alignment: .center, spacing: 12) {
                    entryTile(entry, size: 52)
                    VStack(padding: 0, spacing: 3) {
                        Text(entry.title.isEmpty ? "Untitled" : entry.title, color: PassLook.text,
                             font: fonts.detail, lineLimit: 1)
                        Text(entry.group, color: PassLook.soft, font: fonts.caption, lineLimit: 1)
                    }
                    .flexShrink(1)
                    Spacer()
                    action(entry.recycled ? "Restore…" : "Edit", id: "edit-entry", icon: "edit",
                           enabled: session.writable,
                           run: entryAction(details) { session.editEntry() })
                    if !entry.recycled {
                        action("Move to Recycle Bin", id: "recycle-entry", icon: "trash", style: .icon,
                               enabled: session.writable,
                               run: entryAction(details) { session.confirmRecycle = true })
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                if session.confirmRecycle {
                    detailCard {
                        Text("Move this entry to the Recycle Bin?", color: PassLook.brown)
                            .flexShrink(1)
                        Spacer()
                        action("Cancel", id: "cancel-recycle", style: .ghost,
                               run: entryAction(details) { session.confirmRecycle = false })
                        action("Move to bin", id: "confirm-recycle", style: .primary, enabled: session.writable,
                               run: entryAction(details) { session.recycleEntry() })
                    }
                }
                detailCard {
                    valueLabel("Username", value: entry.username.isEmpty ? "—" : entry.username)
                    Spacer()
                    action("Copy", id: "copy-username", icon: "copy", height: 32,
                           enabled: !entry.username.isEmpty && !session.busy,
                           run: entryAction(details) { session.copyField(entry.username) })
                }
                detailCard {
                    VStack(padding: 0, spacing: 3) {
                        HStack(padding: 0, alignment: .center, spacing: 8, wraps: true) {
                            kicker("Password")
                            if let content {
                                strengthMeter(content.passwordStrength)
                            }
                        }
                        Text(session.revealedPassword ?? "••••••••••••", color: PassLook.text, lineLimit: 1)
                    }
                    .flexShrink(1)
                    Spacer()
                    action(session.revealedPassword == nil ? "Show password" : "Hide password",
                           id: "reveal-entry-password", icon: session.revealedPassword == nil ? "eye" : "eye-off",
                           style: .icon, enabled: !session.busy,
                           run: entryAction(details) { session.toggleEntryPassword() })
                    action("Copy", id: "copy-password", icon: "copy", style: .primary,
                           height: 32, enabled: !session.busy,
                           run: entryAction(details) { session.copyPassword() })
                }
                if !entry.url.isEmpty {
                    let link = websiteURL(entry.url)
                    detailCard {
                        VStack(padding: 0, spacing: 4) {
                            kicker("Website")
                            if let link {
                                Text(entry.url, color: PassLook.orange, hoverColor: PassLook.brown, lineLimit: 1,
                                     onClick: entryAction(details) { session.openWebsite(link) })
                                    .cursor(.pointer)
                                    .tooltip("Open website")
                            } else {
                                Text(entry.url, color: PassLook.text, lineLimit: 1)
                            }
                        }
                        .flexShrink(1)
                        Spacer()
                        action("Copy", id: "copy-url", icon: "copy", height: 32,
                               run: entryAction(details) { session.copyField(entry.url) })
                    }
                }
                if let content {
                    notesCard(content, details: details)
                    attachmentCard(content, details: details)
                    if let modified = content.modified {
                        Text("Modified \(modified.formatted(date: .abbreviated, time: .omitted))",
                             color: PassLook.soft, font: fonts.caption)
                    }
                } else {
                    Text("Could not load entry details.", color: PassLook.soft, font: fonts.caption)
                }
                if entry.customFieldCount > 0 {
                    Text("\(entry.customFieldCount) custom fields preserved", color: PassLook.soft, font: fonts.caption)
                }
            }
        }
    }

    /// A retained panel can still receive a press while another entry loads.
    private func entryAction(_ details: PassSession.EntryDetails, _ run: @escaping () -> Void) -> () -> Void {
        {
            guard session.canAct(on: details) else { return }
            run()
        }
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(padding: 12, alignment: .center, spacing: 8, content: content)
            .background(PassLook.surface)
            .cornerRadius(20)
    }

    private func valueLabel(_ label: String, value: String) -> some View {
        VStack(padding: 0, spacing: 4) {
            kicker(label)
            Text(value, color: PassLook.text, lineLimit: 1)
        }
        .flexShrink(1)
    }

    private func websiteURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func notesCard(_ content: VaultEntryContent, details: PassSession.EntryDetails) -> some View {
        VStack(padding: 14, spacing: 6) {
            HStack(padding: 0, alignment: .center) {
                kicker("Notes")
                Spacer()
                if !content.notes.isEmpty {
                    action("Copy", id: "copy-notes", icon: "copy", height: 30,
                           run: entryAction(details) { session.copyField(content.notes) })
                }
            }
            Text(content.notes.isEmpty ? "No notes" : content.notes,
                 color: content.notes.isEmpty ? PassLook.soft : PassLook.text)
                .agentId("entry-notes-display")
        }
        .background(PassLook.surface)
        .cornerRadius(20)
    }

    private func attachmentCard(_ content: VaultEntryContent, details: PassSession.EntryDetails) -> some View {
        VStack(padding: 12, spacing: 8) {
            HStack(padding: 0, alignment: .center, spacing: 10) {
                PassIcon(symbol: "attachment", color: PassLook.muted, size: 16)
                VStack(padding: 0, spacing: 3) {
                    Text("Attachments", color: PassLook.text, font: fonts.strong)
                    Text(content.attachments.isEmpty ? "No files attached. Drop a file here or add one."
                         : "\(content.attachments.count) attached", color: PassLook.soft, font: fonts.caption)
                }
                .flexShrink(1)
                Spacer()
                action("Add file…", id: "add-attachment", height: 32,
                       enabled: session.writable, run: entryAction(details) { session.addAttachment() })
            }
            ForEach(content.attachments) { attachment in
                attachmentRow(attachment, details: details)
            }
        }
        .border(PassLook.faint)
        .cornerRadius(20)
        .onDrop { files in
            guard session.canAct(on: details), let file = files.first else { return }
            session.importAttachment(file)
        }
    }

    private func strengthMeter(_ strength: PasswordStrength) -> some View {
        HStack(padding: 0, alignment: .center, spacing: 4) {
            Canvas(width: .pt(68), height: .pt(5)) { list, box in
                for bar in 0..<4 {
                    let fill = bar < strength.rawValue ? (strength.rawValue > 2 ? PassLook.sage : PassLook.accent) : PassLook.faint
                    list.roundedRect(x: box.x + Float(bar) * 17, y: box.y, w: 14, h: 4, color: fill, radius: 2)
                }
            }
            Text(strength.label, color: strength.rawValue > 2 ? PassLook.sageInk : PassLook.brown, font: fonts.caption)
        }
        .tooltip("Estimate based on length and character variety")
    }

    private func attachmentRow(_ attachment: VaultAttachment, details: PassSession.EntryDetails) -> some View {
        VStack(padding: 10, spacing: 8) {
            Text(attachment.name, color: Theme.current.textPrimary)
                .agentId("attachment-name-\(attachment.id)")
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file),
                 color: Theme.current.textDim)
            HStack(padding: 0, alignment: .center, spacing: 6) {
                Button("Open", isEnabled: !session.busy,
                       action: entryAction(details) { session.openAttachment(attachment) })
                    .tooltip("Open a private temporary copy; removed when the vault locks")
                    .agentId("open-attachment-\(attachment.id)")
                Button("Save As…", isEnabled: !session.busy,
                       action: entryAction(details) { session.saveAttachment(attachment) })
                    .agentId("save-attachment-\(attachment.id)")
                Spacer()
                Button("Remove", isEnabled: session.writable,
                       action: entryAction(details) { session.attachmentPendingRemoval = attachment })
                    .agentId("remove-attachment-\(attachment.id)")
            }
            if session.attachmentPendingRemoval?.id == attachment.id {
                Text("Remove this attachment? The previous copy remains in entry history.", color: Theme.current.textSecondary)
                HStack(padding: 0, alignment: .center, spacing: 6) {
                    Button("Cancel", action: entryAction(details) { session.attachmentPendingRemoval = nil })
                    Spacer()
                    Button("Remove Attachment", isEnabled: session.writable,
                           action: entryAction(details) { session.removeAttachment() })
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
        labeled(label) {
            inputPill(key == \.url ? "link" : "file") {
                TextField(text: draftBinding(key), placeholder: label,
                          focusRing: .rounded, restingOutline: false)
                    .flexGrow(1)
                    .agentId(id)
            }
        }
    }
}

private struct PassIcon: View {
    let symbol: String
    let color: Color
    var size: Float = 18

    var body: some View {
        Icon(path, size: size, color: color, strokeWidth: 2)
    }

    private var path: String {
        switch symbol {
        case "plus": "M12 5v14M5 12h14"
        case "minus": "M5 12h14"
        case "check": "M5 12l4 4L19 6"
        case "link": "M10 13a4 4 0 0 0 6 0l3-3a4.2 4.2 0 0 0-6-6l-2 2M14 11a4 4 0 0 0-6 0l-3 3a4.2 4.2 0 0 0 6 6l2-2"
        case "folder": "M3 7a2 2 0 0 1 2-2h4.2l2 2.2H19a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"
        case "trash": "M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"
        case "key": "M15.5 7.5 19 4M21 2l-2 2 3 3-3.5 3.5-3-3M14.2 9.8a5 5 0 1 1-7 7 5 5 0 0 1 7-7Z"
        case "file": "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7ZM14 2v4a2 2 0 0 0 2 2h4"
        case "vault": "M4 7h16v13H4zM8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M12 12v3"
        case "shield": "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10ZM10 11V9.5a2 2 0 0 1 4 0V11M9 11h6v4.5H9z"
        case "clock": "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 7v5l3 2"
        case "close": "M6 6l12 12M18 6 6 18"
        case "chevron": "m9 6 6 6-6 6"
        case "search": "M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16ZM21 21l-4.4-4.4"
        case "list": "M3 5h18M3 12h18M3 19h18"
        case "copy": "M9 9h11v11H9zM5 15H4V4h11v1"
        case "edit": "M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"
        case "attachment": "m21 11-8.5 8.5a4.5 4.5 0 0 1-6.4-6.4l8-8a3 3 0 0 1 4.2 4.2l-8 8a1.5 1.5 0 0 1-2.1-2.1l7-7"
        case "eye": "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12ZM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z"
        case "eye-off": "M3 3l18 18M10.6 5.1A9.8 9.8 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-3.2 4.1M6.6 6.6A17 17 0 0 0 2 12s3.5 7 10 7a9.6 9.6 0 0 0 5.4-1.6M9.9 9.9a3 3 0 0 0 4.2 4.2"
        default: "M5 11h14v10H5zM8 11V7a4 4 0 0 1 8 0v4"
        }
    }
}
