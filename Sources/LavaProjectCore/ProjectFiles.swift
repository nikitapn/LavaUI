import Foundation

/// The files of a project as ripgrep walks it: `.gitignore`, `.ignore` and
/// hidden folders respected, so a build directory or a vendored checkout is
/// not "the project".
public enum ProjectFiles {
    /// Absolute paths under `root`, or nil when ripgrep is not installed or
    /// failed. Blocking: call it off the main thread.
    public static func list(root: URL) -> [String]? {
        guard let executable = ProjectSearchEngine.findRipgrep() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--files", "--null"]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 1 is "no files"; anything above is an error.
        guard process.terminationStatus <= 1 else { return nil }
        let base = root.standardizedFileURL.path
        return data.split(separator: 0).map { base + "/" + String(decoding: $0, as: UTF8.self) }
    }
}
