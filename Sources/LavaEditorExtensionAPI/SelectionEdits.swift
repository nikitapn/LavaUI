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
