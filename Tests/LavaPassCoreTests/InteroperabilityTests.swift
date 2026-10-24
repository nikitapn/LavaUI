import Foundation
import Glibc
import Testing
import LavaPassCore

@Suite("KeePassXC interoperability", .enabled(if: ProcessInfo.processInfo.environment["LAVA_KEEPASSXC_CLI"] != nil))
struct InteroperabilityTests {
    private func run(_ args: [String], password: String) throws -> (Int32, String) {
        let cli = try #require(ProcessInfo.processInfo.environment["LAVA_KEEPASSXC_CLI"])
        // Use a bounded POSIX child: Foundation's Process reaper can stall
        // alongside the C++ runtime in the aggregate Linux test executable.
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw POSIXError(.EIO) }
        defer { for fd in input + output where fd >= 0 { _ = close(fd) } }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        for fd in input + output { posix_spawn_file_actions_addclose(&actions, fd) }
        let argv = (["timeout", "20", cli] + args).map { strdup($0) } + [nil]
        var env = ProcessInfo.processInfo.environment
        if let library = env["LAVA_KEEPASSXC_LIBRARY_PATH"] { env["LD_LIBRARY_PATH"] = library }
        let environment = env.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + environment { if let pointer { free(pointer) } } }
        var pid: pid_t = 0
        let status = posix_spawnp(&pid, "timeout", &actions, nil, argv, environment)
        guard status == 0 else { throw POSIXError(.EIO) }
        _ = close(input[0]); input[0] = -1
        _ = close(output[1]); output[1] = -1
        let bytes = Array((password + "\n").utf8)
        _ = bytes.withUnsafeBytes { Glibc.write(input[1], $0.baseAddress, $0.count) }
        _ = close(input[1]); input[1] = -1
        var exitStatus: Int32 = 0
        while waitpid(pid, &exitStatus, 0) < 0 {
            if errno != EINTR { throw POSIXError(.ECHILD) }
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Glibc.read(output[0], &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return ((exitStatus >> 8) & 0xff, String(decoding: data, as: UTF8.self))
    }

    @Test("KeePassXC opens a LavaPass vault, edits it, and LavaPass reopens the result")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lavapass-interop-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shared.kdbx")
        let doc = try VaultDocument.create(url: url, password: "interop-master")
        let group = try #require(doc.snapshot.groups.first?.id)
        var draft = CredentialDraft(groupID: group)
        draft.title = "Example"; draft.username = "alice"; draft.password = "interop-entry-secret"
        draft.notes = "Unicode note: café ✓\nSecond line"
        try doc.save(draft)
        let shown = try run(["show", "-s", "-a", "Password", url.path, "Example"], password: "interop-master")
        #expect(shown.0 == 0)
        #expect(shown.1.trimmingCharacters(in: .whitespacesAndNewlines) == draft.password)
        let edited = try run(["edit", "-u", "bob", url.path, "Example"], password: "interop-master")
        #expect(edited.0 == 0)
        let reopened = try VaultDocument(url: url, password: "interop-master")
        let item = try #require(reopened.snapshot.entries.first)
        #expect(item.username == "bob")
        #expect(try reopened.password(for: item.id) == draft.password)
        #expect(try reopened.draft(for: item.id).notes == draft.notes)
    }
    @Test("Attachment bytes and notes survive edits by both LavaPass and KeePassXC")
    func attachments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lavapass-attachment-interop-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = dir.appendingPathComponent("shared.kdbx")
        let doc = try VaultDocument.create(url: vault, password: "interop-master")
        var draft = CredentialDraft(groupID: try #require(doc.snapshot.groups.first?.id))
        draft.title = "Example"; draft.notes = "Optional notes\nUnicode: café ✓"
        let id = try doc.save(draft)
        let bytes = Data((0..<1024).map { UInt8($0 % 256) })
        try doc.addAttachment(entryID: id, name: "payload.bin", data: bytes)
        let exported = dir.appendingPathComponent("reference-export.bin")
        let result = try run(["attachment-export", vault.path, "Example", "payload.bin", exported.path], password: "interop-master")
        #expect(result.0 == 0)
        #expect(try Data(contentsOf: exported) == bytes)
        let referenceInput = dir.appendingPathComponent("reference-input.txt")
        let referenceBytes = Data("A file added by KeePassXC".utf8)
        try referenceBytes.write(to: referenceInput)
        let imported = try run(["attachment-import", vault.path, "Example", "from-reference.txt", referenceInput.path], password: "interop-master")
        #expect(imported.0 == 0)
        let reopened = try VaultDocument(url: vault, password: "interop-master")
        let content = try reopened.entryContent(for: id)
        let attachment = try #require(content.attachments.first { $0.name == "from-reference.txt" })
        #expect(try reopened.attachmentData(entryID: id, attachmentID: attachment.id) == referenceBytes)
        #expect(content.notes == draft.notes)
        try reopened.removeAttachment(entryID: id, attachmentID: attachment.id)
        let remaining = dir.appendingPathComponent("remaining.bin")
        let checked = try run(["attachment-export", vault.path, "Example", "payload.bin", remaining.path], password: "interop-master")
        #expect(checked.0 == 0)
        #expect(try Data(contentsOf: remaining) == bytes)
    }

}
