import Foundation

/// Native "open"/"save" file picker.
///
/// Linux only, backed by `zenity` (GTK's own file chooser, invoked as a
/// subprocess — the common approach for a GLFW/Vulkan app that has no GTK
/// event loop of its own to host a real widget in). Blocks the calling
/// thread until the user picks a file or cancels, same as any native modal
/// dialog; call it from the main loop between frames, not from a paint
/// closure. Returns `nil` on cancel, on a platform with no backend here, or
/// if `zenity` isn't installed — callers should treat all three the same
/// way ("no file chosen"), not surface them as distinct errors.
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
        run(["--file-selection", "--title=\(title)"] + filterArgs(filters))
    }

    public static func openFiles(
        title: String = "Open Files", filters: [Filter] = []
    ) -> [URL] {
        run(
            ["--file-selection", "--multiple", "--separator=\n", "--title=\(title)"]
                + filterArgs(filters),
            multiple: true
        )
    }

    public static func saveFile(
        title: String = "Save File", filters: [Filter] = [], defaultName: String? = nil
    ) -> URL? {
        var args = ["--file-selection", "--save", "--confirm-overwrite", "--title=\(title)"]
        if let defaultName { args.append("--filename=\(defaultName)") }
        return run(args + filterArgs(filters))
    }

    private static func filterArgs(_ filters: [Filter]) -> [String] {
        filters.map { "--file-filter=\($0.name) | " + $0.extensions.map { "*.\($0)" }.joined(separator: " ") }
    }

    private static func run(_ args: [String]) -> URL? {
        run(args, multiple: false).first
    }

    private static func run(_ args: [String], multiple: Bool) -> [URL] {
        #if os(Linux)
        guard let zenity = which("zenity") else {
            FileHandle.standardError.write(
                Data("FileDialog: zenity not found on PATH\n".utf8)
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
        #else
        return []
        #endif
    }

    private static func which(_ binary: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
