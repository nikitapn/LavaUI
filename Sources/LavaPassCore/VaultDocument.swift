import Foundation
import Glibc
import KDBXKit

public enum VaultError: Error, LocalizedError {
    case cannotOpen, unlockFailed, cannotSave, changedOnDisk, readOnly, missingEntry, invalidEntry, alreadyExists
    case missingAttachment, duplicateAttachment, cannotReadAttachment, attachmentTooLarge, cannotExportAttachment
    public var errorDescription: String? {
        switch self {
        case .cannotOpen: "Could not read this vault or key file."
        case .unlockFailed: "Could not unlock the vault. Check the password and key file, or whether the file uses a supported KDBX format."
        case .cannotSave: "Could not save the vault. The previous vault has not been replaced."
        case .changedOnDisk: "The vault changed on disk. Lock and reopen it before editing so another application's changes are preserved."
        case .readOnly: "This vault is open read-only."
        case .missingEntry: "This entry or group no longer exists."
        case .invalidEntry: "Enter a title for this entry."
        case .alreadyExists: "A file already exists at that location. Choose a new filename."
        case .missingAttachment: "This attachment is missing or could not be read."
        case .duplicateAttachment: "An attachment with this filename already exists. Rename the file or remove the existing attachment first."
        case .cannotReadAttachment: "Could not read this attachment file."
        case .attachmentTooLarge: "Attachments can be up to 128 MiB each."
        case .cannotExportAttachment: "Could not save the attachment at that location."

        }
    }
}

public struct VaultGroup: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var depth: Int
    public var recycleBin: Bool
}

public struct VaultEntry: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var groupID: UUID
    public var title: String
    public var username: String
    public var url: String
    public var group: String
    public var recycled: Bool
    public var attachmentCount: Int
    public var customFieldCount: Int
}

public struct VaultSnapshot: Sendable {
    public var name: String
    public var path: String
    public var groups: [VaultGroup]
    public var entries: [VaultEntry]
    public var readOnlyReason: String?
    public var canSaveCopy: Bool
}

public struct VaultAttachment: Identifiable, Sendable, Equatable {
    public var id: Int
    public var name: String
    public var size: Int
}

/// Selected-entry content excludes the password; reading notes must not reveal it.
public struct VaultEntryContent: Sendable {
    public var entryID: UUID
    public var notes: String
    public var attachments: [VaultAttachment]
}

public struct CredentialDraft: Equatable, Sendable {
    public var id: UUID?
    public var groupID: UUID
    public var title = ""
    public var username = ""
    public var password = ""
    public var url = ""
    public var notes = ""
    public init(id: UUID? = nil, groupID: UUID) { self.id = id; self.groupID = groupID }
}

/// Owns decrypted library objects. The app confines each document to one worker queue.
/// Passwords remain protected by KDBXKit until explicitly edited or copied.
public final class VaultDocument {
    public private(set) var url: URL
    private var content: KDBXContent
    private let unlock: UnlockData
    private var original: Data

    public init(url: URL, password: String, keyFile: URL? = nil) throws {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        let data: Data
        let key: Data?
        do {
            data = try Data(contentsOf: self.url)
            key = try keyFile.map { try Data(contentsOf: $0) }
        } catch { throw VaultError.cannotOpen }
        do {
            if password.isEmpty, let key { unlock = try UnlockData(keyFile: key) }
            else { unlock = try UnlockData(masterPassword: password, keyFile: key) }
            content = try KDBXReader.parse(data, unlockData: unlock)
        } catch { throw VaultError.unlockFailed }
        original = data
    }

    private init(url: URL, content: KDBXContent, unlock: UnlockData, original: Data) {
        self.url = url; self.content = content; self.unlock = unlock; self.original = original
    }

    public static func create(url: URL, password: String) throws -> VaultDocument {
        guard !password.isEmpty else { throw VaultError.unlockFailed }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let content = KDBXContent.makeEmpty(databaseName: url.deletingPathExtension().lastPathComponent, generator: "LavaPass")
        let unlock = UnlockData(masterPassword: password)
        let bytes: Data
        do { bytes = try Self.encode(content, unlock: unlock) }
        catch { throw VaultError.cannotSave }
        try PrivateVaultFile.write(bytes, to: url, replace: false)
        return VaultDocument(url: url, content: content, unlock: unlock, original: bytes)
    }

    public var snapshot: VaultSnapshot {
        var groups: [VaultGroup] = []
        var entries: [VaultEntry] = []
        func visit(_ group: KDBX.Group, depth: Int, parentPath: String, recycled: Bool) {
            let recycled = recycled || group.uuid == content.database.meta.recycleBinUUID
            let name = group.name ?? "Untitled Group"
            let path = parentPath.isEmpty ? name : parentPath + " / " + name
            groups.append(VaultGroup(id: group.uuid, name: name, depth: depth, recycleBin: recycled))
            for entry in group.entries {
                entries.append(VaultEntry(id: entry.uuid, groupID: group.uuid,
                    title: field(entry, "Title"), username: field(entry, "UserName"), url: field(entry, "URL"),
                    group: path, recycled: recycled, attachmentCount: entry.binaries.count,
                    customFieldCount: entry.strings.filter { !["Title", "UserName", "Password", "URL", "Notes"].contains($0.key) }.count))
            }
            for child in group.groups { visit(child, depth: depth + 1, parentPath: path, recycled: recycled) }
        }
        visit(content.database.root.group, depth: 0, parentPath: "", recycled: false)
        let reason: String?
        if !content.parserWarnings.isEmpty {
            reason = "Read-only: this vault contains data this version cannot safely preserve when saving."
        } else if content.header.formatVersion.major < 4 {
            reason = "KDBX 3 vault — read-only. Save a KDBX 4 copy to enable editing; the original will stay unchanged."
        } else { reason = nil }
        return VaultSnapshot(name: content.database.meta.databaseName ?? url.deletingPathExtension().lastPathComponent,
            path: url.path, groups: groups, entries: entries, readOnlyReason: reason,
            canSaveCopy: content.parserWarnings.isEmpty)
    }

    public func draft(for id: UUID) throws -> CredentialDraft {
        guard let entry = find(id, in: content.database.root.group),
              let summary = snapshot.entries.first(where: { $0.id == id }) else { throw VaultError.missingEntry }
        var draft = CredentialDraft(id: id, groupID: summary.groupID)
        draft.title = field(entry, "Title"); draft.username = field(entry, "UserName")
        draft.password = field(entry, "Password"); draft.url = field(entry, "URL"); draft.notes = field(entry, "Notes")
        return draft
    }

    public func entryContent(for id: UUID) throws -> VaultEntryContent {
        guard let entry = find(id, in: content.database.root.group) else { throw VaultError.missingEntry }
        let attachments = try entry.binaries.enumerated().map { index, binary in
            VaultAttachment(id: index, name: binary.key, size: try binaryData(binary).count)
        }
        return VaultEntryContent(entryID: id, notes: field(entry, "Notes"), attachments: attachments)
    }

    public func attachmentData(entryID: UUID, attachmentID: Int) throws -> Data {
        guard let entry = find(entryID, in: content.database.root.group),
              entry.binaries.indices.contains(attachmentID) else { throw VaultError.missingAttachment }
        return try binaryData(entry.binaries[attachmentID])
    }

    public static let maximumAttachmentSize = 128 * 1024 * 1024

    public func importAttachment(entryID: UUID, from file: URL) throws {
        guard snapshot.readOnlyReason == nil else { throw VaultError.readOnly }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.resolvingSymlinksInPath().path) }
        catch { throw VaultError.cannotReadAttachment }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw VaultError.cannotReadAttachment }
        guard let size = (attributes[.size] as? NSNumber)?.intValue else { throw VaultError.cannotReadAttachment }
        guard size <= Self.maximumAttachmentSize else { throw VaultError.attachmentTooLarge }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw VaultError.cannotReadAttachment }
        try addAttachment(entryID: entryID, name: file.lastPathComponent, data: data)
    }

    public func addAttachment(entryID: UUID, name: String, data: Data) throws {
        guard !name.isEmpty else { throw VaultError.cannotReadAttachment }
        guard data.count <= Self.maximumAttachmentSize else { throw VaultError.attachmentTooLarge }
        try commit { next in
            let slot: Int
            if let existing = next.innerHeader.binaryContent.firstIndex(where: { $0.data == data }) { slot = existing }
            else {
                slot = next.innerHeader.binaryContent.count
                next.innerHeader.binaryContent.append(.init(shouldBeProtected: true, data: data))
            }
            guard let reference = UInt32(exactly: slot) else { throw VaultError.cannotSave }
            guard try mutateEntry(entryID, in: &next.database.root.group, { entry in
                guard !entry.binaries.contains(where: { $0.key == name }) else { throw VaultError.duplicateAttachment }
                Self.recordHistory(&entry)
                entry.binaries.append(.init(key: name, value: .ref(reference)))
            }) else { throw VaultError.missingEntry }
        }
    }

    public func removeAttachment(entryID: UUID, attachmentID: Int) throws {
        try commit { next in
            guard try mutateEntry(entryID, in: &next.database.root.group, { entry in
                guard entry.binaries.indices.contains(attachmentID) else { throw VaultError.missingAttachment }
                Self.recordHistory(&entry)
                entry.binaries.remove(at: attachmentID)
                // Keep pool slots intact: other entries and history may still reference them.
            }) else { throw VaultError.missingEntry }
        }
    }

    /// Plaintext leaves the vault only at the user's explicit export/open request.
    /// Never overwrite an existing file, the vault, or its encrypted backup.
    public func exportAttachment(entryID: UUID, attachmentID: Int, to destination: URL) throws {
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard destination != url, destination != url.appendingPathExtension("bak") else { throw VaultError.alreadyExists }
        let bytes = try attachmentData(entryID: entryID, attachmentID: attachmentID)
        do { try PrivateVaultFile.write(bytes, to: destination, replace: false) }
        catch VaultError.alreadyExists { throw VaultError.alreadyExists }
        catch { throw VaultError.cannotExportAttachment }
    }

    /// Vault filenames are labels, not paths. Use only a bounded basename for external files.
    public static func attachmentFilename(_ name: String) -> String {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let last = String(normalized.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
        let clean = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "attachment" }
        let ext = String((clean as NSString).pathExtension.prefix(20))
        let suffix = ext.isEmpty ? "" : "." + ext
        var stem = ext.isEmpty ? clean : (clean as NSString).deletingPathExtension
        while (stem + suffix).utf8.count > 200 { stem.removeLast() }
        return (stem.isEmpty ? "attachment" : stem) + suffix
    }

    private func binaryData(_ binary: KDBX.ProtectedBinary) throws -> Data {
        switch binary.value {
        case .inline(let data, _): return data
        case .ref(let index):
            guard Int(index) < content.innerHeader.binaryContent.count else { throw VaultError.missingAttachment }
            return content.innerHeader.binaryContent[Int(index)].data
        }
    }

    private static func recordHistory(_ entry: inout KDBX.Entry) {
        var previous = entry; previous.history = []
        entry.history.append(previous)
        var times = entry.times ?? .init()
        times.lastModificationTime = Date(); entry.times = times
    }

    private func mutateEntry(_ id: UUID, in group: inout KDBX.Group,
                             _ change: (inout KDBX.Entry) throws -> Void) throws -> Bool {
        if let index = group.entries.firstIndex(where: { $0.uuid == id }) { try change(&group.entries[index]); return true }
        for index in group.groups.indices {
            if try mutateEntry(id, in: &group.groups[index], change) { return true }
        }
        return false
    }

    public func password(for id: UUID) throws -> String {
        guard let entry = find(id, in: content.database.root.group) else { throw VaultError.missingEntry }
        return field(entry, "Password")
    }

    @discardableResult
    public func save(_ draft: CredentialDraft) throws -> UUID {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.invalidEntry }
        let savedID = draft.id ?? UUID()
        try commit { next in
            var entry: KDBX.Entry
            if let id = draft.id {
                guard let old = find(id, in: next.database.root.group) else { throw VaultError.missingEntry }
                entry = old
                var history = old; history.history = []
                entry.history.append(history)
                guard remove(id, from: &next.database.root.group) != nil else { throw VaultError.missingEntry }
            } else { entry = KDBX.Entry(uuid: savedID, times: .init(creationTime: Date())) }
            for (key, value) in [("Title", draft.title), ("UserName", draft.username), ("Password", draft.password), ("URL", draft.url), ("Notes", draft.notes)] {
                let existing = entry.strings.firstIndex { $0.key == key }
                let protected: Bool
                if key == "Password" { protected = true }
                else if let existing, case .regular = entry.strings[existing].value { protected = false }
                else { protected = existing != nil }
                let field = KDBX.ProtectedString(key: key, value: protected ? .unprotected(value) : .regular(value))
                if let existing { entry.strings[existing] = field } else { entry.strings.append(field) }
            }
            var times = entry.times ?? .init()
            times.lastModificationTime = Date(); entry.times = times
            guard mutateGroup(draft.groupID, in: &next.database.root.group, { $0.entries.append(entry) }) else { throw VaultError.missingEntry }
        }
        return savedID
    }

    public func addGroup(name: String, parent: UUID) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw VaultError.invalidEntry }
        try commit { next in
            let group = KDBX.Group(uuid: UUID(), name: name, times: .init(creationTime: Date(), lastModificationTime: Date()))
            guard mutateGroup(parent, in: &next.database.root.group, { $0.groups.append(group) }) else { throw VaultError.missingEntry }
        }
    }

    public func recycle(_ id: UUID) throws {
        try commit { next in
            guard let parent = snapshot.entries.first(where: { $0.id == id }), !parent.recycled,
                  var entry = remove(id, from: &next.database.root.group) else { throw VaultError.missingEntry }
            // Always offer reversible removal, even for vaults that previously disabled the bin.
            var recycleID = next.database.meta.recycleBinUUID
            if recycleID == nil || !snapshot.groups.contains(where: { $0.id == recycleID }) {
                recycleID = UUID()
                next.database.root.group.groups.append(KDBX.Group(uuid: recycleID!, name: "Recycle Bin"))
                next.database.meta.recycleBinUUID = recycleID
            }
            next.database.meta.recycleBinEnabled = true
            next.database.meta.recycleBinChanged = Date()
            entry.previousParentGroup = parent.groupID
            guard mutateGroup(recycleID!, in: &next.database.root.group, { $0.entries.append(entry) }) else { throw VaultError.missingEntry }
        }
    }

    public func saveCopy(to destination: URL) throws -> VaultDocument {
        guard content.parserWarnings.isEmpty else { throw VaultError.readOnly }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let bytes: Data
        do { bytes = try Self.encode(content, unlock: unlock) }
        catch { throw VaultError.cannotSave }
        try PrivateVaultFile.write(bytes, to: target, replace: false)
        let parsed: KDBXContent
        do { parsed = try KDBXReader.parse(bytes, unlockData: unlock) }
        catch { throw VaultError.cannotSave }
        return VaultDocument(url: target, content: parsed, unlock: unlock, original: bytes)
    }

    private func commit(_ change: (inout KDBXContent) throws -> Void) throws {
        guard snapshot.readOnlyReason == nil else { throw VaultError.readOnly }
        guard (try? Data(contentsOf: url)) == original else { throw VaultError.changedOnDisk }
        var next = content
        try change(&next)
        let encoded: Data
        do { encoded = try Self.encode(next, unlock: unlock) }
        catch { throw VaultError.cannotSave }
        guard (try? Data(contentsOf: url)) == original else { throw VaultError.changedOnDisk }
        try PrivateVaultFile.write(original, to: url.appendingPathExtension("bak"), replace: true)
        try PrivateVaultFile.write(encoded, to: url, replace: true)
        content = next; original = encoded
    }

    private static func encode(_ content: KDBXContent, unlock: UnlockData) throws -> Data {
        let stream = OutputStream.toMemory()
        stream.open()
        defer { stream.close() }
        try KDBXWriter(to: stream).write(content, unlockData: unlock)
        guard let data = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data else { throw VaultError.cannotSave }
        return data
    }

    private func field(_ entry: KDBX.Entry, _ name: String) -> String {
        entry.strings.first { $0.key == name }?.value.withRevealedString { $0 } ?? ""
    }
    private func find(_ id: UUID, in group: KDBX.Group) -> KDBX.Entry? {
        if let entry = group.entries.first(where: { $0.uuid == id }) { return entry }
        for child in group.groups { if let entry = find(id, in: child) { return entry } }
        return nil
    }
    private func remove(_ id: UUID, from group: inout KDBX.Group) -> KDBX.Entry? {
        if let index = group.entries.firstIndex(where: { $0.uuid == id }) { return group.entries.remove(at: index) }
        for index in group.groups.indices {
            if let entry = remove(id, from: &group.groups[index]) { return entry }
        }
        return nil
    }
    private func mutateGroup(_ id: UUID, in group: inout KDBX.Group, _ change: (inout KDBX.Group) -> Void) -> Bool {
        if group.uuid == id { change(&group); return true }
        for index in group.groups.indices {
            if mutateGroup(id, in: &group.groups[index], change) { return true }
        }
        return false
    }
}

/// Owner-only atomic writes for encrypted vaults and explicitly requested attachment exports.
private enum PrivateVaultFile {
    static func write(_ data: Data, to url: URL, replace: Bool) throws {
        var template = Array((url.deletingLastPathComponent().path + "/.lavapass-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw VaultError.cannotSave }
        let temp = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { _ = close(fd); _ = unlink(temp) }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw VaultError.cannotSave }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Glibc.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VaultError.cannotSave }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw VaultError.cannotSave }
        if replace {
            guard rename(temp, url.path) == 0 else { throw VaultError.cannotSave }
        } else {
            // link fails if the destination already exists; never overwrite a vault on Create/Save Copy.
            guard link(temp, url.path) == 0 else { throw errno == EEXIST ? VaultError.alreadyExists : VaultError.cannotSave }
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        if directory >= 0 { _ = fsync(directory); _ = close(directory) }
    }
}
