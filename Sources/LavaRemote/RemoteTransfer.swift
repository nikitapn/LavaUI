import Foundation
import LavaExplorerCore

/// Carries out a `RemoteTransferPlan`. Blocking, for a worker thread.
///
/// Folders are walked: an upload makes each folder on the server (merging
/// into one already there) and sends every file under it; a download lists
/// each remote folder as it goes. Nothing half-written is left behind — a
/// download goes to a hidden name and is renamed when complete, and an upload
/// cut short is removed from the server.
public enum RemoteTransfer {
    /// Bytes so far, bytes in all (0 while unknown), and the file being sent.
    public typealias Progress = (_ done: Int64, _ total: Int64, _ name: String) -> Void

    public static func run(
        _ plan: RemoteTransferPlan, clashes choice: ClashChoice,
        connections: RemoteConnections, logins: RemoteLogins,
        isCancelled: @escaping () -> Bool, progress: @escaping Progress
    ) -> RemoteTransferOutcome {
        var outcome = RemoteTransferOutcome()
        var meter = Meter(total: plan.items.reduce(0) { $0 + ($1.size ?? 0) }, report: progress)
        for item in plan.items {
            if isCancelled() { outcome.cancelled = true; break }
            guard let name = plan.destinationName(of: item, choice) else {
                outcome.skipped += 1
                continue
            }
            let failure = step(
                item, as: name, in: plan.direction, connections: connections,
                logins: logins, isCancelled: isCancelled, meter: &meter
            )
            guard let failure else {
                outcome.done += 1
                continue
            }
            if failure.kind == .cancelled {
                outcome.cancelled = true
                break
            }
            outcome.failures.append(FileAccessError(path: item.source, message: failure.message))
            if outcome.error == nil { outcome.error = failure }
            // A login refused, a host gone: everything after this would fail
            // the same way, one timeout at a time.
            if [.login, .connect, .hostKey, .tls].contains(failure.kind) { break }
        }
        return outcome
    }

    /// One top-level item, and what stopped it if anything did.
    static func step(
        _ item: RemoteTransferPlan.Item, as name: String, in direction: RemoteTransferPlan.Direction,
        connections: RemoteConnections, logins: RemoteLogins,
        isCancelled: @escaping () -> Bool, meter: inout Meter
    ) -> RemoteError? {
        do {
            switch direction {
            case .upload(let folder):
                try upload(
                    item.source, isDirectory: item.isDirectory, to: folder.appending(name),
                    connections: connections, as: logins.credentials(for: folder.server),
                    isCancelled: isCancelled, meter: &meter
                )
            case .download(let folder):
                guard let remote = RemoteURL(item.source) else {
                    return RemoteError(.failed, "Not a server address: \(item.source)")
                }
                try download(
                    remote, isDirectory: item.isDirectory, to: join(folder, name),
                    connections: connections, as: logins.credentials(for: remote.server),
                    isCancelled: isCancelled, meter: &meter
                )
            }
            return nil
        } catch {
            return error
        }
    }

    /// Counts bytes across the whole transfer, so the percentage is of all
    /// of it rather than starting again at every file.
    struct Meter {
        var total: Int64
        var finished: Int64 = 0
        let report: Progress

        func tick(_ done: Int64, _ name: String) {
            report(finished + done, total, name)
        }
    }

    // MARK: - Up

    static func upload(
        _ local: String, isDirectory: Bool, to remote: RemoteURL,
        connections: RemoteConnections, as creds: RemoteCredentials,
        isCancelled: @escaping () -> Bool, meter: inout Meter
    ) throws(RemoteError) {
        guard isDirectory else {
            try uploadFile(local, to: remote, connections: connections, as: creds,
                           isCancelled: isCancelled, meter: &meter)
            return
        }
        try? connections.makeFolder(remote, as: creds)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: local).sorted()
        } catch {
            throw RemoteError(.failed, "Cannot read \(local)")
        }
        for name in names {
            if isCancelled() { throw RemoteError(.cancelled, "Cancelled") }
            let path = join(local, name)
            guard let entry = try? LocalFileSource().entry(at: path) else { continue }
            // A link to a folder would be followed into wherever it points —
            // possibly a loop. Sent as the file it is, or not at all.
            if entry.isSymlink, entry.isDirectory { continue }
            try upload(path, isDirectory: entry.isDirectory, to: remote.appending(name),
                       connections: connections, as: creds,
                       isCancelled: isCancelled, meter: &meter)
        }
    }

    static func uploadFile(
        _ local: String, to remote: RemoteURL,
        connections: RemoteConnections, as creds: RemoteCredentials,
        isCancelled: @escaping () -> Bool, meter: inout Meter
    ) throws(RemoteError) {
        let size = (try? LocalFileSource().entry(at: local))?.size ?? 0
        let m = meter
        do throws(RemoteError) {
            try connections.upload(local, to: remote, as: creds) { done, _ in
                m.tick(done, remote.name)
                return !isCancelled()
            }
        } catch {
            // Half a file on the server is worse than none.
            try? connections.removeFile(remote, as: creds)
            throw error
        }
        meter.finished += size
    }

    // MARK: - Down

    static func download(
        _ remote: RemoteURL, isDirectory: Bool, to local: String,
        connections: RemoteConnections, as creds: RemoteCredentials,
        isCancelled: @escaping () -> Bool, meter: inout Meter
    ) throws(RemoteError) {
        guard isDirectory else {
            try downloadFile(remote, to: local, connections: connections, as: creds,
                             isCancelled: isCancelled, meter: &meter)
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        } catch {
            throw RemoteError(.failed, "Cannot make \(local)")
        }
        let rows = try connections.list(remote, as: creds)
        for row in rows {
            if isCancelled() { throw RemoteError(.cancelled, "Cancelled") }
            guard let child = RemoteURL(row.path) else { continue }
            if row.isSymlink, row.isDirectory { continue }
            try download(child, isDirectory: row.isDirectory,
                         to: join(local, row.name),
                         connections: connections, as: creds,
                         isCancelled: isCancelled, meter: &meter)
        }
    }

    /// Into a hidden name beside the destination, renamed over it once it is
    /// all there — so a cancelled or failed download leaves nothing, and a
    /// replaced file is replaced only by a whole one.
    static func downloadFile(
        _ remote: RemoteURL, to local: String,
        connections: RemoteConnections, as creds: RemoteCredentials,
        isCancelled: @escaping () -> Bool, meter: inout Meter
    ) throws(RemoteError) {
        let folder = (local as NSString).deletingLastPathComponent
        let part = join(
            folder, ".\((local as NSString).lastPathComponent).lavapart-\(UUID().uuidString.prefix(8))"
        )
        let m = meter
        var size: Int64 = 0
        do throws(RemoteError) {
            try connections.download(remote, to: part, as: creds) { done, _ in
                size = max(size, done)
                m.tick(done, remote.name)
                return !isCancelled()
            }
        } catch {
            try? FileManager.default.removeItem(atPath: part)
            throw error
        }
        if rename(part, local) != 0 {
            try? FileManager.default.removeItem(atPath: part)
            throw RemoteError(.failed, "Cannot write \(local)")
        }
        meter.finished += size
    }
}

private func join(_ directory: String, _ name: String) -> String {
    (directory as NSString).appendingPathComponent(name)
}
