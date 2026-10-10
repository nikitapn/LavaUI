import Foundation
import LavaIDL
import NPRPC

/// The way to `lava-index`, the per-user file index (`idl/index.npidl`).
///
/// Per *user*, not per session, so unlike `ControlPlane.referencePath` there
/// is no session in the name: a nested compositor searches the same files as
/// the outer one.
///
/// Rides the NPRPC runtime the process already has — `LavaClient.open` starts
/// it — so this is a reference and a narrow, not a second transport. Call it
/// after `open`.
public enum FileIndex {
    public static var referencePath: String {
        let environment = ProcessInfo.processInfo.environment
        if let forced = environment["LAVA_INDEX_IOR"], !forced.isEmpty { return forced }
        let base = environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        return (base as NSString).appendingPathComponent("lava-index.ior")
    }

    public enum Failure: Error, CustomStringConvertible {
        /// No reference: the daemon is not running (or never was).
        case notRunning(path: String)
        case badReference
        case notAnIndex

        public var description: String {
            switch self {
            case .notRunning(let path):
                return "lava-index is not running (no \(path)); "
                    + "systemctl --user start lava-index"
            case .badReference: return "lava-index published an unreadable reference"
            case .notAnIndex: return "the reference is not a lava.index.Index"
            }
        }
    }

    /// A proxy to the running daemon.
    public static func connect() throws -> Index {
        let path = referencePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure.notRunning(path: path)
        }
        let ior = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = NPRPCObject.fromString(ior), object.selectEndpoint() else {
            throw Failure.badReference
        }
        guard let index = narrow(object, to: Index.self) else { throw Failure.notAnIndex }
        return index
    }

    nonisolated(unsafe) private static var shared: Index?
    private static let lock = NSLock()

    /// "The user opened this", for the Recent list. Fire-and-forget, and
    /// silent when there is no daemon: opening a file must never wait on, or
    /// fail because of, the index.
    public static func noteOpened(_ path: String, appId: String) {
        lock.lock()
        if shared == nil { shared = try? connect() }
        let index = shared
        lock.unlock()
        guard let index else { return }
        Task.detached { await index.noteOpened(path: path, appId: appId) }
    }
}
