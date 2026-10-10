import Foundation
import LavaIDL
import NPRPC

/// The way to `lava-index`, the per-user file index (`idl/index.npidl`).
///
/// Per *user*, not per session, so unlike `ControlPlane.referencePath` there
/// is no session in the name: a nested compositor searches the same files as
/// the outer one.
///
/// Rides the NPRPC runtime the process already has when it is a compositor
/// client — `LavaClient.open` starts it — and starts one of its own when it
/// is not: a windowed LavaView has opened files too, and they belong in
/// Recent as much as anything else.
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

    /// The runtime this file started, for a process that had none. Held for
    /// the process's lifetime: the `Rpc` owns the transport.
    nonisolated(unsafe) private static var ownRuntime: Rpc?

    /// A proxy to the running daemon.
    public static func connect() throws -> Index {
        let path = referencePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure.notRunning(path: path)
        }
        let ior = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if LavaClient.runtime == nil && ownRuntime == nil {
            let rpc = try RpcBuilder().setLogLevel(.warn).build()
            try rpc.startThreadPool(1)
            ownRuntime = rpc
        }
        guard let object = NPRPCObject.fromString(ior), object.selectEndpoint() else {
            throw Failure.badReference
        }
        guard let index = narrow(object, to: Index.self) else { throw Failure.notAnIndex }
        return index
    }

    /// The proxy, and the reference it was made from. A daemon restart (every
    /// `packaging/install.sh` is one) publishes a new reference, and a proxy
    /// to the old process would swallow every note without a word.
    nonisolated(unsafe) private static var shared: (ior: String, index: Index)?
    private static let lock = NSLock()

    /// "The user opened this", for the Recent list. Fire-and-forget, and
    /// silent when there is no daemon: opening a file must never wait on, or
    /// fail because of, the index.
    ///
    /// Safe from any thread. Reconnects when the published reference changes,
    /// so a daemon started or restarted after this process is still told.
    /// In a compositor client, call it after `LavaClient.open`, which is what
    /// starts the runtime this rides; before it, this would start a second.
    public static func noteOpened(_ path: String, appId: String) {
        guard path.hasPrefix("/"),
              let text = try? String(contentsOfFile: referencePath, encoding: .utf8)
        else { return }
        let ior = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if shared?.ior != ior {
            shared = (try? connect()).map { (ior, $0) }
        }
        let index = shared?.index
        lock.unlock()
        guard let index else { return }
        Task.detached { await index.noteOpened(path: path, appId: appId) }
    }
}
