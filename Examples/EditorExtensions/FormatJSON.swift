import Foundation
import LavaEditorExtensionAPI

@_cdecl("lava_editor_activate_v1")
public func activate(_ command: UnsafePointer<CChar>, _ reference: UnsafePointer<CChar>, _ invocation: UInt64) -> Int32 {
    let options: JSONSerialization.WritingOptions
    switch String(cString: command) {
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
