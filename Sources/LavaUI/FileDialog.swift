import Foundation

/// Native "open"/"save" file picker.
///
/// The picker is LavaExplorer, run as `LavaExplorer --choose=…` — the same
/// file manager, with a bar along the bottom for the name and the answer, so
/// Open… in any Lava app looks like the desktop it is on. It is found at
/// `LAVA_FILE_CHOOSER` (a path to the binary), next to the running app's own
/// binary (every app in this package builds into one directory), or on
/// `PATH`, in that order. Without one, `zenity` — GTK's chooser — as before;
/// `LAVA_FILE_CHOOSER=zenity` asks for it outright.
///
/// It is a subprocess either way, for the reason zenity was: a picker is a
/// window, and a client has one surface. The chosen paths come back through
/// a file named on the command line rather than stdout, which an app is free
/// to fill with anything.
///
/// Blocks the calling thread until the user picks or cancels, same as any
/// native modal dialog; call it from the main loop between frames, not from
/// a paint closure. Returns `nil` on cancel, on a platform with no backend,
/// or with no picker installed — callers should treat all three the same way
/// ("no file chosen"), not surface them as distinct errors.
public enum FileDialog {
    public struct Filter {
        public var name: String
        public var extensions: [String]

        public init(name: String, extensions: [String]) {
            self.name = name
            self.extensions = extensions
        }
    }

    public static func openFile(
        title: String = "Open File", filters: [Filter] = []
    ) -> URL? {
        run(Request(mode: .open, title: title, filters: filters)).first
    }

    public static func openFiles(
        title: String = "Open Files", filters: [Filter] = []
    ) -> [URL] {
        run(Request(mode: .openMultiple, title: title, filters: filters))
    }

    public static func saveFile(
        title: String = "Save File", filters: [Filter] = [], defaultName: String? = nil
    ) -> URL? {
        run(Request(mode: .save, title: title, filters: filters, defaultName: defaultName)).first
    }

    /// Where the next dialog opens: wherever the last one chose from, so a
    /// second Open… lands where the first left off. The process's working
    /// directory is `/` for anything a launcher started, which is nowhere.
    nonisolated(unsafe) private static var lastDirectory: String?

    struct Request {
        enum Mode: String { case open, openMultiple = "open-multiple", save }
        var mode: Mode
        var title: String
        var filters: [Filter]
        var defaultName: String? = nil
    }

    private static func run(_ request: Request) -> [URL] {
        #if os(Linux)
        let chosen: [URL]
        if let explorer = explorerBinary() {
            chosen = runExplorer(explorer, request)
        } else {
            chosen = runZenity(request)
        }
        if let first = chosen.first {
            lastDirectory = first.deletingLastPathComponent().path
        }
        return chosen
        #else
        return []
        #endif
    }

    // MARK: LavaExplorer

    static func explorerArguments(
        _ request: Request, output: String, start: String
    ) -> [String] {
        var args = [
            "--choose=\(request.mode.rawValue)",
            "--title=\(request.title)",
            "--output=\(output)",
        ]
        args += request.filters.map {
            "--filter=\($0.name)|" + $0.extensions.joined(separator: ",")
        }
        // An app that narrows the list still leaves a way to see everything.
        if !request.filters.isEmpty {
            args.append("--filter=All files|")
        }
        if let name = request.defaultName { args.append("--filename=\(name)") }
        args.append(start)
        return args
    }

    private static func runExplorer(_ binary: String, _ request: Request) -> [URL] {
        let output = NSTemporaryDirectory() + "lava-choice-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: output) }
        let start = lastDirectory ?? NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = explorerArguments(request, output: output, start: start)
        // The explorer's own chatter is not the caller's business.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(
                Data("FileDialog: could not start \(binary): \(error)\n".utf8)
            )
            return runZenity(request)
        }
        process.waitUntilExit()
        // The answer is the file, whatever the exit status says: a client
        // whose surface closes leaves through a watchdog with status 0.
        guard let text = try? String(contentsOfFile: output, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
    }

    /// `LAVA_FILE_CHOOSER`, then beside this binary, then `PATH`.
    static func explorerBinary() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let chosen = env["LAVA_FILE_CHOOSER"], !chosen.isEmpty {
            if chosen == "zenity" { return nil }
            return FileManager.default.isExecutableFile(atPath: chosen) ? chosen : nil
        }
        if let own = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let sibling = own.deletingLastPathComponent().appendingPathComponent("LavaExplorer").path
            // Not the explorer asking itself: it would open a picker inside a
            // picker, forever, if it ever called this.
            if sibling != own.path, FileManager.default.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        return which("LavaExplorer")
    }

    // MARK: zenity

    private static func runZenity(_ request: Request) -> [URL] {
        var args = ["--file-selection", "--title=\(request.title)"]
        switch request.mode {
        case .open: break
        case .openMultiple: args += ["--multiple", "--separator=\n"]
        case .save:
            args += ["--save", "--confirm-overwrite"]
            if let name = request.defaultName { args.append("--filename=\(name)") }
        }
        args += request.filters.map {
            "--file-filter=\($0.name) | " + $0.extensions.map { "*.\($0)" }.joined(separator: " ")
        }
        guard let zenity = which("zenity") else {
            FileHandle.standardError.write(
                Data("FileDialog: neither LavaExplorer nor zenity found\n".utf8)
            )
            return []
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zenity)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()  // discard GTK theme/module warnings
        do {
            try process.run()
            process.waitUntilExit()
            // Non-zero: cancelled, or the dialog window was closed. Not an
            // error worth distinguishing from "chose nothing".
            guard process.terminationStatus == 0 else { return [] }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0)) }
        } catch {
            FileHandle.standardError.write(
                Data("FileDialog: failed to launch zenity: \(error)\n".utf8)
            )
            return []
        }
    }

    private static func which(_ binary: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
