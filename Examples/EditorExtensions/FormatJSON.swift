import Foundation
import LavaEditorExtensionAPI

@_cdecl("lava_editor_activate_v1")
public func activate(_ command: UnsafePointer<CChar>, _ reference: UnsafePointer<CChar>, _ invocation: UInt64) -> Int32 {
    let options: JSONSerialization.WritingOptions
    switch String(cString: command) {
    case "overview": return renderOverview(reference, invocation: invocation)
    case "sort-lines", "word-count", "open-readme":
        return runTextCommand(String(cString: command), reference, invocation: invocation)
    case "preview":
        return runMarkdownPreviewProvider(reference) { editor in
            let source = try await editor.readDocument(invocation: invocation)
            let json = try JSONSerialization.jsonObject(with: Data(source.text.utf8), options: [.fragmentsAllowed])
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [
                .prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes,
            ])
            let markdown = "```json\n" + String(decoding: bytes, as: UTF8.self) + "\n```"
            guard try await editor.setMarkdown(invocation: invocation, markdown: markdown) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    case "format": options = [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
    case "compact": options = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
    default: return 2
    }
    return runEditorCommand(reference) { editor in
        let selection = try await editor.readSelection(invocation: invocation)
        let value = try JSONSerialization.jsonObject(with: Data(selection.text.utf8), options: [.fragmentsAllowed])
        let formatted = try JSONSerialization.data(withJSONObject: value, options: options)
        let edit = SelectionEdit(startByte: selection.startByte, endByte: selection.endByte,
                                 text: String(decoding: formatted, as: UTF8.self))
        let status = try await editor.proposeEdits(invocation: invocation, documentId: selection.documentId,
                                                   revision: selection.revision, edits: [edit])
        guard status == .accepted else { throw CocoaError(.fileWriteUnknown) }
    }
}
