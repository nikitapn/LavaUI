import Foundation

/// Preorder rows keep a scroll offset independent of the height of a subtree.
/// Format scalar values only for rows that are actually painted.
struct JSONTree {
    struct Row {
        let depth: Int
        let label: String
        let scalar: Any?

        func text() throws -> String {
            guard let scalar else { return label }
            return label + (try JSONTree.literal(scalar))
        }
    }

    private let root: Any
    private(set) var rows: [Row] = []
    private(set) var descending: Bool

    init(text: String, descending: Bool) throws {
        root = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        self.descending = descending
        try rebuild()
    }

    mutating func order(descending: Bool) throws {
        guard descending != self.descending else { return }
        self.descending = descending
        try rebuild()
    }

    private static func literal(_ value: Any) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func rebuild() throws {
        rows.removeAll(keepingCapacity: true)
        try append(root, label: "", depth: 0)
    }

    private mutating func append(_ value: Any, label: String, depth: Int) throws {
        if let object = value as? [String: Any] {
            if !label.isEmpty || object.isEmpty {
                rows.append(Row(depth: depth, label: label + (object.isEmpty ? "{}" : "Object (\(object.count))"), scalar: nil))
            }
            let keys = object.keys.sorted(by: descending ? (>) : (<))
            for key in keys {
                if let child = object[key] {
                    try append(child, label: Self.literal(key) + ": ", depth: label.isEmpty ? depth : depth + 1)
                }
            }
        } else if let array = value as? [Any] {
            if !label.isEmpty || array.isEmpty {
                rows.append(Row(depth: depth, label: label + (array.isEmpty ? "[]" : "Array (\(array.count))"), scalar: nil))
            }
            for (index, child) in array.enumerated() {
                try append(child, label: "[\(index)]  ", depth: label.isEmpty ? depth : depth + 1)
            }
        } else {
            rows.append(Row(depth: depth, label: label, scalar: value))
        }
    }
}
