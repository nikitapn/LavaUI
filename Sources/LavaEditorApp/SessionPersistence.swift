import Foundation
import LavaProjectCore
import LavaUI

extension EditorSessionSnapshot.Position {
    init(_ position: EditorPosition) {
        self.init(scrollX: position.scrollX, scrollY: position.scrollY,
                  anchor: position.anchor, focus: position.focus,
                  topOffset: position.topOffset, topFraction: position.topFraction)
    }

    var editorPosition: EditorPosition {
        EditorPosition(scrollX: scrollX, scrollY: scrollY, anchor: anchor, focus: focus,
                       topOffset: topOffset, topFraction: topFraction)
    }
}

/// The compositor can exit the process from its input thread. Keep an immutable
/// snapshot and its destination so the exit hook can save without reading the UI.
final class SessionPersistence: @unchecked Sendable {
    static let shared = SessionPersistence()

    private struct Checkpoint: Equatable {
        let snapshot: EditorSessionSnapshot
        let workspace: URL?
    }

    private let lock = NSLock()
    private var latest: Checkpoint?
    private var saved: Checkpoint?
    private var scheduled = false

    private init() {
        atexit { SessionPersistence.shared.flush() }
    }

    func checkpoint(_ snapshot: EditorSessionSnapshot, workspace: URL?) {
        lock.lock()
        defer { lock.unlock() }
        let checkpoint = Checkpoint(snapshot: snapshot, workspace: workspace)
        guard latest != checkpoint else { return }
        latest = checkpoint
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            self.flushScheduled()
        }
    }

    /// The outgoing session is flushed before a workspace is opened or saved.
    /// Start the new checkpoint from its current state so simply opening a file
    /// does not rewrite it.
    func adoptWorkspace(_ snapshot: EditorSessionSnapshot, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let checkpoint = Checkpoint(snapshot: snapshot, workspace: url)
        latest = checkpoint
        saved = checkpoint
    }

    static func writeWorkspace(_ snapshot: EditorSessionSnapshot, to url: URL) throws {
        try EditorWorkspace.encode(snapshot, at: url).write(to: url, options: .atomic)
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
    }

    private func flushScheduled() {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        flushLocked()
    }

    private func flushLocked() {
        guard let latest, latest != saved else { return }
        // An older worker must never overwrite the final snapshot on exit.
        if let url = latest.workspace {
            do {
                try Self.writeWorkspace(latest.snapshot, to: url)
            } catch {
                FileHandle.standardError.write(
                    Data("Could not checkpoint \(url.path): \(error.localizedDescription)\n".utf8)
                )
                return
            }
        } else {
            AppSettings.set(latest.snapshot, forKey: "session")
        }
        saved = latest
    }
}
