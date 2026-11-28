/// A prefix consumes one non-modifier key. The app supplies the bindings and
/// decides whether the focused control owns the prefix key.
public struct EditorKeyChord<Action: Equatable> {
    public struct Stroke: Hashable {
        public let key: Int32
        public let modifiers: Int32

        public init(_ key: Int32, modifiers: Int32 = 0) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    public enum Result: Equatable {
        case pass, prefix, cancel, undefined(Stroke), action(Action)
    }

    private let prefix: Stroke
    private let bindings: [Stroke: Action]
    private let cancelKeys: Set<Stroke>
    public private(set) var isPending = false

    public init(prefix: Stroke, bindings: [Stroke: Action], cancelKeys: Set<Stroke>) {
        self.prefix = prefix
        self.bindings = bindings
        self.cancelKeys = cancelKeys
    }

    public mutating func reset() { isPending = false }

    public mutating func press(_ stroke: Stroke, prefixAvailable: Bool = true, isRepeat: Bool = false,
                               isModifier: Bool = false) -> Result {
        guard !isModifier else { return .pass }
        if isPending {
            if isRepeat, stroke == prefix { return .prefix }
            reset()
            if cancelKeys.contains(stroke) { return .cancel }
            if let action = bindings[stroke] { return .action(action) }
            return .undefined(stroke)
        }
        guard stroke == prefix, prefixAvailable, !isRepeat else { return .pass }
        isPending = true
        return .prefix
    }
}
