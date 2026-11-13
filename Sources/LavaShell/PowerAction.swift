import Foundation

/// systemd owns hardware support, authorization and inhibitors. In particular,
/// sleep goes through logind so the compositor can lock before it happens.
public enum PowerAction: String, Sendable, CaseIterable {
    case sleep = "suspend"
    case hibernate
    case powerOff = "poweroff"

    public var title: String {
        switch self {
        case .sleep: return "Sleep"
        case .hibernate: return "Hibernate"
        case .powerOff: return "Power Off"
        }
    }

    /// Blocking: call on a worker, never on the panel's input thread.
    /// No forced shutdown or inhibitor bypass, and no invisible password prompt.
    public func perform() -> String? {
        perform(executable: URL(fileURLWithPath: "/usr/bin/systemctl"))
    }

    // An explicit executable lets tests exercise the process boundary without
    // ever asking the host to sleep or shut down.
    func perform(executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-ask-password", "--check-inhibitors=yes", rawValue]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            // Drain before waiting: an inhibitor report can fill the pipe.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                let detail = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "The system refused the request." : detail
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
