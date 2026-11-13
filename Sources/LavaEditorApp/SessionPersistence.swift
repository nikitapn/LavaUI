import Foundation
import LavaUI

/// Only disk-backed documents belong to a session; this is not draft recovery.
struct SavedEditorSession: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var path: String
        var position: EditorPosition
    }
    var files: [File]
    var activePath: String?
    var fontSize: Int?
}

/// The compositor can exit the process from its input thread. Keep an immutable
/// snapshot there is no UI work left to do to save, including in the exit hook.
final class SessionPersistence: @unchecked Sendable {
    static let shared = SessionPersistence()
    private let lock = NSLock()
    private var latest: SavedEditorSession?
    private var saved: SavedEditorSession?
    private var scheduled = false

    private init() {
        atexit { SessionPersistence.shared.flush() }
    }

    func checkpoint(_ snapshot: SavedEditorSession) {
        lock.lock()
        defer { lock.unlock() }
        guard latest != snapshot else { return }
        latest = snapshot
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            self.flush()
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        guard let latest, latest != saved else { return }
        // Serialize the write with snapshots and the exit hook: an older
        // worker must never overwrite the final position on its way out.
        AppSettings.set(latest, forKey: "session")
        saved = latest
    }
}
