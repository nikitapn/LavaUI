import Foundation
import Glibc
import LavaPassCore
import LavaShell

/// Only explicit attachment-open actions create these owner-only directories.
/// Track them before exporting so a simultaneous lock cannot leave a cleartext copy behind.
enum AttachmentFiles {
    private static let mutex = NSLock()
    nonisolated(unsafe) private static var directories: [URL] = []

    static func temporaryURL(name: String) throws -> URL {
        mutex.lock()
        defer { mutex.unlock() }
        var template = Array((FileManager.default.temporaryDirectory.path + "/lavapass-attachment-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw VaultError.cannotReadAttachment }
        let directory = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        directories.append(directory)
        return directory.appendingPathComponent(VaultDocument.attachmentFilename(name))
    }

    static func clear() {
        mutex.lock()
        defer { mutex.unlock() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    static func open(_ file: URL) -> Bool {
        let mime = MimeApps.type(of: file.path, isDirectory: false)
        MimeApps.invalidateDefaults()
        if mime != "application/octet-stream",
           let app = MimeApps.preferredApplication(for: mime, applications: DesktopEntry.installed()) {
            return app.launch(files: [file.path])
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let binary = String(directory) + "/xdg-open"
            guard FileManager.default.isExecutableFile(atPath: binary) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); return true } catch { return false }
        }
        return false
    }
}
