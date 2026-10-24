import Foundation
import Testing
import KDBXKit
@testable import LavaPassCore

@Suite("LavaPass vaults", .serialized)
struct VaultTests {
    private func fixture(_ name: String, _ ext: String = "kdbx") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources"))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lavapass-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func copyFixture(_ name: String, to directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(name + ".kdbx")
        try FileManager.default.copyItem(at: fixture(name), to: destination)
        return destination
    }
    private func parsed(_ url: URL, password: String) throws -> KDBXContent {
        try KDBXReader.parse(Data(contentsOf: url), unlockData: UnlockData(masterPassword: password))
    }
    private func entry(_ id: UUID, in group: KDBX.Group) -> KDBX.Entry? {
        group.entries.first { $0.uuid == id } ?? group.groups.compactMap { entry(id, in: $0) }.first
    }

    @Test("New vaults reopen, wrong passwords fail, saves are encrypted and backed up")
    func createAndSave() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Personal.kdbx")
        let doc = try VaultDocument.create(url: path, password: "master-test-password")
        let before = try Data(contentsOf: path)
        let group = try #require(doc.snapshot.groups.first?.id)
        var draft = CredentialDraft(groupID: group)
        draft.title = "Example Account"; draft.username = "alice@example.test"
        draft.password = "UNIQUE_SECRET_NEVER_PLAINTEXT_98123"; draft.notes = "Private note"
        try doc.save(draft)
        let reopened = try VaultDocument(url: path, password: "master-test-password")
        let saved = try #require(reopened.snapshot.entries.first)
        #expect(try reopened.password(for: saved.id) == draft.password)
        #expect(try Data(contentsOf: path.appendingPathExtension("bak")) == before)
        #expect(!String(decoding: try Data(contentsOf: path), as: UTF8.self).contains(draft.password))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: VaultError.self) { try VaultDocument(url: path, password: "wrong") }
        #expect(throws: VaultError.self) { try VaultDocument.create(url: path, password: "other") }
        #expect(try reopened.password(for: saved.id) == draft.password)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".lavapass-") })
    }

    @Test("KeePassXC attachments, custom fields, history and other entries survive editing")
    func preserveExistingData() throws {
        for (name, password) in [("kpxc-rich", "123"), ("kpxc-extras", "test")] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = try copyFixture(name, to: dir)
            let before = try parsed(path, password: password)
            let doc = try VaultDocument(url: path, password: password)
            #expect(doc.snapshot.readOnlyReason == nil)
            let summary = try #require(doc.snapshot.entries.first { !$0.recycled })
            let old = try #require(entry(summary.id, in: before.database.root.group))
            var draft = try doc.draft(for: summary.id)
            draft.password = "new-example-password"
            try doc.save(draft)
            let after = try parsed(path, password: password)
            let updated = try #require(entry(summary.id, in: after.database.root.group))
            #expect(updated.binaries == old.binaries)
            #expect(updated.customData == old.customData)
            #expect(updated.autoType == old.autoType)
            #expect(updated.tags == old.tags)
            #expect(after.innerHeader.binaryContent == before.innerHeader.binaryContent)
            #expect(updated.history.count == old.history.count + 1)
            for field in old.strings where !["Title", "UserName", "Password", "URL", "Notes"].contains(field.key) {
                #expect(updated.strings.first { $0.key == field.key }?.value.revealedString == field.value.revealedString)
            }
            for other in doc.snapshot.entries where other.id != summary.id {
                #expect(entry(other.id, in: before.database.root.group) == entry(other.id, in: after.database.root.group))
            }
        }
    }

    @Test("An external writer's changes are never overwritten")
    func conflict() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = try copyFixture("kpxc-rich", to: dir)
        let doc = try VaultDocument(url: path, password: "123")
        let item = try #require(doc.snapshot.entries.first)
        let draft = try doc.draft(for: item.id)
        let external = Data("External change".utf8)
        try external.write(to: path)
        do { try doc.save(draft); Issue.record("Save should have refused changed content") }
        catch VaultError.changedOnDisk {}
        #expect(try Data(contentsOf: path) == external)
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathExtension("bak").path))
    }

    @Test("Legacy vaults stay unchanged until an explicit KDBX 4 copy is saved")
    func legacyCopy() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = try copyFixture("kpxc-kdbx31-default", to: dir)
        let original = try Data(contentsOf: path)
        let doc = try VaultDocument(url: path, password: "test")
        #expect(doc.snapshot.readOnlyReason != nil)
        #expect(doc.snapshot.canSaveCopy)
        let copy = try doc.saveCopy(to: dir.appendingPathComponent("upgraded.kdbx"))
        #expect(copy.snapshot.readOnlyReason == nil)
        #expect(copy.snapshot.entries.count == doc.snapshot.entries.count)
        #expect(try Data(contentsOf: path) == original)
        #expect(try parsed(URL(fileURLWithPath: copy.snapshot.path), password: "test").header.formatVersion.major == 4)
        #expect(throws: VaultError.self) { try doc.saveCopy(to: path) }
    }

    @Test("Existing key files remain required")
    func keyFile() throws {
        let path = try fixture("kpxc-keyfile")
        #expect(throws: VaultError.self) { try VaultDocument(url: path, password: "123") }
        let doc = try VaultDocument(url: path, password: "123", keyFile: fixture("kpxc-keyfile", "key"))
        #expect(!doc.snapshot.entries.isEmpty)
    }

    @Test("Recycle and restore retain the original entry and its password")
    func recycleAndRestore() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = try copyFixture("kpxc-rich", to: dir)
        let doc = try VaultDocument(url: path, password: "123")
        let selected = try #require(doc.snapshot.entries.first { !$0.recycled })
        let original = try doc.password(for: selected.id)
        try doc.recycle(selected.id)
        #expect(doc.snapshot.entries.first { $0.id == selected.id }?.recycled == true)
        var draft = try doc.draft(for: selected.id)
        draft.groupID = selected.groupID
        try doc.save(draft)
        #expect(doc.snapshot.entries.first { $0.id == selected.id }?.recycled == false)
        #expect(try doc.password(for: selected.id) == original)
    }

    @Test("Generated passwords have bounded length and include selected character classes")
    func generator() {
        for length in [0, 12, 24, 64, 1000] {
            let password = PasswordGenerator.generate(length: length)
            #expect(password.count == max(4, min(length, 256)))
            #expect(password.contains { $0.isUppercase })
            #expect(password.contains { $0.isLowercase })
            #expect(password.contains { $0.isNumber })
            #expect(password.contains { !$0.isLetter && !$0.isNumber })
        }
        #expect(PasswordGenerator.generate(symbols: false).allSatisfy { $0.isLetter || $0.isNumber })
    }
}
