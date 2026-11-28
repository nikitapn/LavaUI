import Foundation
import LavaEditorExtensionAPI

/// General commands (`"kind": "command"`): one each for what a command can
/// ask the editor for — edits, a message, a file opened.
func runTextCommand(_ name: String, _ reference: UnsafePointer<CChar>, invocation: UInt64) -> Int32 {
    switch name {
    case "sort-lines":
        // The lines the selection touches, or the caret's line — sorted,
        // as one undo step.
        return runCommand(reference) { editor in
            let context = try await editor.readContext(invocation: invocation)
            guard context.hasDocument else { return }
            let range = context.selectedLines
            let bytes = Array(context.text.utf8)[Int(range.lowerBound)..<Int(range.upperBound)]
            let block = String(decoding: bytes, as: UTF8.self)
            let endsWithNewline = block.hasSuffix("\n")
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if endsWithNewline { lines.removeLast() }
            guard lines.count > 1 else {
                _ = try await editor.showMessage(invocation: invocation, message: "Select two or more lines to sort.")
                return
            }
            let sorted = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let edit = SelectionEdit(startByte: range.lowerBound, endByte: range.upperBound,
                                     text: sorted.joined(separator: "\n") + (endsWithNewline ? "\n" : ""))
            let status = try await editor.proposeEdits(invocation: invocation, documentId: context.documentId,
                                                       revision: context.revision, edits: [edit])
            guard status == .accepted else { throw CocoaError(.fileWriteUnknown) }
        }
    case "word-count":
        return runCommand(reference) { editor in
            let context = try await editor.readContext(invocation: invocation)
            guard context.hasDocument else {
                _ = try await editor.showMessage(invocation: invocation, message: "No document to count.")
                return
            }
            let text = context.selectedText ?? context.text
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let scope = context.selectedText == nil ? "Document" : "Selection"
            _ = try await editor.showMessage(invocation: invocation,
                                             message: "\(scope): \(words) words, \(text.count) characters")
        }
    case "open-readme":
        return runCommand(reference) { editor in
            let context = try await editor.readContext(invocation: invocation)
            let names = ["README.md", "README", "readme.md", "README.txt"]
            let root = context.projectRoot
            guard !root.isEmpty,
                  let name = names.first(where: { FileManager.default.fileExists(atPath: root + "/" + $0) }) else {
                _ = try await editor.showMessage(invocation: invocation, message: "No README in the open folder.")
                return
            }
            _ = try await editor.openFile(invocation: invocation, path: name, line: 1)
        }
    case "mark-todos":
        // Every TODO and FIXME in the document as a problem: a warning for
        // FIXME, information for TODO. Run again after fixing them and the
        // list empties — a publish replaces this command's last one.
        return runCommand(reference) { editor in
            let context = try await editor.readContext(invocation: invocation)
            guard context.hasDocument, !context.path.isEmpty else {
                _ = try await editor.showMessage(invocation: invocation, message: "Save the file first.")
                return
            }
            var found: [ExtensionDiagnostic] = []
            for (number, line) in context.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for (marker, severity) in [("FIXME", UInt32(2)), ("TODO", UInt32(3))] {
                    guard let range = line.range(of: marker) else { continue }
                    let start = line.utf8.distance(from: line.startIndex, to: range.lowerBound)
                    let note = line[range.upperBound...].drop { $0 == ":" || $0 == " " }
                    found.append(ExtensionDiagnostic(
                        startLine: UInt32(number), startColumn: UInt32(start),
                        endLine: UInt32(number), endColumn: UInt32(start + marker.utf8.count),
                        severity: severity, message: note.isEmpty ? marker : "\(marker): \(note)"))
                }
            }
            _ = try await editor.publishDiagnostics(invocation: invocation, path: context.path, diagnostics: found)
            _ = try await editor.showMessage(invocation: invocation,
                                             message: found.isEmpty ? "No TODOs." : "\(found.count) marked.")
        }
    default:
        return 2
    }
}
