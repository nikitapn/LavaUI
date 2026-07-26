/// The value type carried by a `Slot`. Deliberately simpler than the
/// original C++ model's `CSlotType` hierarchy (`CValue`/`CValueRef`/
/// `CFixedValue`/`COutsideReference`/`CAvrInternalPin`/...): that hierarchy
/// existed to resolve values *across networked AVR controllers at runtime*,
/// which isn't this editor's job (see `Slot.source` for the one piece of
/// that we do still need — knowing whether a slot is wired internally or
/// bound to an external I/O point).
public enum SignalType: Hashable, Sendable {
    case bool
    /// `bits` is 8/16/32; `signed` distinguishes e.g. Int16 vs UInt16.
    /// Deliberately not tied to any particular MCU's native word size —
    /// this editor targets multiple microcontroller families (AVR today,
    /// STM32 later), so "what sizes/encodings a given target supports" is
    /// a concern for a future code-gen backend, not this model.
    case int(bits: Int, signed: Bool)
    case float

    /// Whether a value of `other` can flow into a slot of this type
    /// without an explicit conversion block. For now this is exact-match
    /// only (including bit width) — widening/narrowing conversions are a
    /// deliberate non-goal until there's a real second use case for them.
    public func isCompatible(with other: SignalType) -> Bool {
        self == other
    }
}

extension SignalType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bool: return "BOOL"
        case .int(let bits, let signed): return "\(signed ? "I" : "U")\(bits)"
        case .float: return "FLOAT"
        }
    }
}
