import Foundation
import Testing
import KDBXKit
@testable import LavaPassCore

@Suite("LavaPass attachments and notes", .serialized)
struct AttachmentTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lavapass-attachments-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func newEntry(_ document: VaultDocument, title: String) throws -> UUID {
        let group = try #require(document.snapshot.groups.first?.id)
        var draft = CredentialDraft(groupID: group)
        draft.title = title; draft.password = "example-password"
        draft.notes = "Optional notes: café ✓\nSecond line\n\nLast paragraph"
        return try document.save(draft)
    }

    @Test("Binary and empty attachments reopen, export exactly, and preserve optional multiline notes")
    func roundTrip() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let vault = dir.appendingPathComponent("vault.kdbx")
        let document = try VaultDocument.create(url: vault, password: "master")
        let id = try newEntry(document, title: "Example")
        let payload = Data((0..<8192).map { UInt8($0 % 256) })
        let source = dir.appendingPathComponent("picture.bin")
        try payload.write(to: source)
        try document.importAttachment(entryID: id, from: source)
        try document.addAttachment(entryID: id, name: "empty.txt", data: Data())
        let reopened = try VaultDocument(url: vault, password: "master")
        let details = try reopened.entryContent(for: id)
        #expect(details.notes == "Optional notes: café ✓\nSecond line\n\nLast paragraph")
        #expect(details.attachments.map(\.name) == ["picture.bin", "empty.txt"])
        #expect(details.attachments.map(\.size) == [8192, 0])
        let output = dir.appendingPathComponent("exported.bin")
        try reopened.exportAttachment(entryID: id, attachmentID: 0, to: output)
        #expect(try Data(contentsOf: output) == payload)
        #expect((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try reopened.attachmentData(entryID: id, attachmentID: 1).isEmpty)
        var draft = try reopened.draft(for: id)
        draft.notes = ""
        try reopened.save(draft)
        #expect(try reopened.entryContent(for: id).notes.isEmpty)
        #expect(try reopened.attachmentData(entryID: id, attachmentID: 0) == payload)
    }

    @Test("Removing one shared attachment keeps other entries, history, and notes intact")
    func sharedHistory() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let vault = dir.appendingPathComponent("vault.kdbx")
        let document = try VaultDocument.create(url: vault, password: "master")
        let first = try newEntry(document, title: "First"), second = try newEntry(document, title: "Second")
        let payload = Data("Shared attachment payload".utf8)
        try document.addAttachment(entryID: first, name: "shared.txt", data: payload)
        try document.addAttachment(entryID: second, name: "shared.txt", data: payload)
        try document.removeAttachment(entryID: first, attachmentID: 0)
        let reopened = try VaultDocument(url: vault, password: "master")
        #expect(try reopened.entryContent(for: first).attachments.isEmpty)
        #expect(try reopened.attachmentData(entryID: second, attachmentID: 0) == payload)
        #expect(try reopened.entryContent(for: first).notes.hasPrefix("Optional notes:"))
        let parsed = try KDBXReader.parse(Data(contentsOf: vault), unlockData: UnlockData(masterPassword: "master"))
        let entry = try #require(parsed.database.root.group.entries.first { $0.uuid == first })
        let binary = try #require(entry.history.last?.binaries.first)
        if case .ref(let reference) = binary.value {
            #expect(parsed.innerHeader.binaryContent[Int(reference)].data == payload)
        } else { Issue.record("Expected a retained history reference") }
    }

    @Test("Duplicate imports, existing export targets, oversized files, and vault replacement are rejected")
    func refusedActions() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let vault = dir.appendingPathComponent("vault.kdbx")
        let document = try VaultDocument.create(url: vault, password: "master")
        let id = try newEntry(document, title: "Example")
        try document.addAttachment(entryID: id, name: "note.txt", data: Data("Public attachment".utf8))
        let before = try Data(contentsOf: vault)
        do { try document.addAttachment(entryID: id, name: "note.txt", data: Data("Replacement".utf8)); Issue.record("Duplicate accepted") }
        catch VaultError.duplicateAttachment {}
        do { try document.exportAttachment(entryID: id, attachmentID: 0, to: vault); Issue.record("Vault export accepted") }
        catch VaultError.alreadyExists {}
        do { try document.exportAttachment(entryID: id, attachmentID: 0, to: vault.appendingPathExtension("bak")); Issue.record("Backup export accepted") }
        catch VaultError.alreadyExists {}
        let existing = dir.appendingPathComponent("existing.txt")
        try Data("Original file".utf8).write(to: existing)
        do { try document.exportAttachment(entryID: id, attachmentID: 0, to: existing); Issue.record("Existing file overwritten") }
        catch VaultError.alreadyExists {}
        #expect(try String(contentsOf: existing, encoding: .utf8) == "Original file")
        let huge = dir.appendingPathComponent("sparse.bin")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: Data()))
        let file = try FileHandle(forWritingTo: huge)
        try file.truncate(atOffset: UInt64(VaultDocument.maximumAttachmentSize + 1)); try file.close()
        do { try document.importAttachment(entryID: id, from: huge); Issue.record("Oversized file accepted") }
        catch VaultError.attachmentTooLarge {}
        #expect(try Data(contentsOf: vault) == before)
        #expect(throws: VaultError.self) { try document.attachmentData(entryID: id, attachmentID: 99) }
    }

    @Test("Legacy attachments can be read and exported without upgrading or modifying the vault")
    func legacyAttachments() throws {
        let fixture = try #require(Bundle.module.url(forResource: "kpxc-kdbx31-attachments", withExtension: "kdbx", subdirectory: "Resources"))
        let original = try Data(contentsOf: fixture)
        let document = try VaultDocument(url: fixture, password: "test")
        #expect(document.snapshot.readOnlyReason != nil)
        let entry = try #require(document.snapshot.entries.first { $0.attachmentCount > 0 })
        let details = try document.entryContent(for: entry.id)
        #expect(details.attachments.count == 2)
        let note = try #require(details.attachments.first { $0.name == "note.txt" })
        #expect(note.size == 17)
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("note.txt")
        try document.exportAttachment(entryID: entry.id, attachmentID: note.id, to: output)
        #expect(try Data(contentsOf: output).count == 17)
        #expect(throws: VaultError.self) { try document.removeAttachment(entryID: entry.id, attachmentID: note.id) }
        #expect(try Data(contentsOf: fixture) == original)
    }

    @Test("Attachment labels cannot become paths outside the chosen directory")
    func safeNames() {
        #expect(VaultDocument.attachmentFilename("../../secrets/note.txt") == "note.txt")
        #expect(VaultDocument.attachmentFilename("C:\\private\\note.txt") == "note.txt")
        #expect(VaultDocument.attachmentFilename("..") == "attachment")
        #expect(VaultDocument.attachmentFilename("\u{0}notes\n.txt") == "notes.txt")
        let name = VaultDocument.attachmentFilename(String(repeating: "🔒", count: 200) + ".png")
        #expect(name.utf8.count <= 200)
        #expect(name.hasSuffix(".png"))
    }
}
