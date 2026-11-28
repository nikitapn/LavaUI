import Foundation

extension SelectionSnapshot {
    /// Builds the replacement for one undo transaction. Ranges use absolute
    /// document byte offsets so the same snapshot anchors every edit.
    public func applying(_ edits: [SelectionEdit], limit: Int) -> String? {
        guard !edits.isEmpty, startByte <= endByte,
              endByte - startByte == UInt64(text.utf8.count) else { return nil }
        let bytes = text.utf8
        var cursor = bytes.startIndex
        var output = Data()
        for edit in edits {
            guard edit.startByte >= startByte, edit.endByte <= endByte,
                  edit.startByte <= edit.endByte else { return nil }
            let lower = bytes.index(bytes.startIndex, offsetBy: Int(edit.startByte - startByte))
            let upper = bytes.index(bytes.startIndex, offsetBy: Int(edit.endByte - startByte))
            guard lower >= cursor,
                  lower == bytes.endIndex || bytes[lower] & 0xc0 != 0x80,
                  upper == bytes.endIndex || bytes[upper] & 0xc0 != 0x80 else { return nil }
            let prefix = bytes[cursor..<lower]
            guard limit >= output.count, prefix.count <= limit - output.count,
                  edit.text.utf8.count <= limit - output.count - prefix.count else { return nil }
            output.append(contentsOf: prefix)
            output.append(contentsOf: edit.text.utf8)
            cursor = upper
        }
        let suffix = bytes[cursor...]
        guard suffix.count <= limit - output.count else { return nil }
        output.append(contentsOf: suffix)
        return String(decoding: output, as: UTF8.self)
    }
}

extension CommandContext {
    /// The selected text, or nil with nothing selected.
    public var selectedText: String? {
        guard hasDocument, selectionEndByte > selectionStartByte else { return nil }
        let bytes = Array(text.utf8)
        guard selectionEndByte <= UInt64(bytes.count) else { return nil }
        return String(decoding: bytes[Int(selectionStartByte)..<Int(selectionEndByte)], as: UTF8.self)
    }

    /// The byte range of the whole lines the selection touches — or the
    /// caret's line — including the last line's newline. What a line
    /// command (sort, join, duplicate) acts on.
    public var selectedLines: Range<UInt64> {
        let bytes = Array(text.utf8)
        let low = Int(min(selectionStartByte, UInt64(bytes.count)))
        var high = Int(min(selectionEndByte, UInt64(bytes.count)))
        // A selection ending at the start of a line does not take that line.
        if high > low, bytes[high - 1] == 0x0A { high -= 1 }
        var start = low
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = high
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        if end < bytes.count { end += 1 }
        return UInt64(start)..<UInt64(end)
    }

    /// The whole document after `edits`, nil when they are out of order,
    /// overlap, split a character or reach past the end — what the editor
    /// will refuse.
    public func applying(_ edits: [SelectionEdit], limit: Int = 8 << 20) -> String? {
        SelectionSnapshot(documentId: documentId, revision: revision, startByte: 0,
                          endByte: UInt64(text.utf8.count), text: text).applying(edits, limit: limit)
    }
}
