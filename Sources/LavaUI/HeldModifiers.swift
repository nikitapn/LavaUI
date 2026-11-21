/// Which modifier keys are held, between events that say so.
///
/// A pointer move carries no modifiers on either input path, so a view that
/// changes under the pointer while Control is held — a code editor's
/// Ctrl+hover link — cannot read them off the move. Key events and presses do
/// carry them, and this is where they are kept.
///
/// A release that happens in another window is never seen, so the state can
/// go stale while this window is not being used. It is corrected by the next
/// key event or press, and cleared when the pointer leaves the window: a
/// Control that is really still held then lights things up again on its next
/// key repeat or press, which is a much smaller fault than one that is stuck.
public enum HeldModifiers {
    nonisolated(unsafe) public private(set) static var control = false

    /// From a key event. The modifier bits a press of Control itself reports
    /// can be the state from before the press, so Control's own key decides.
    /// Returns whether `control` changed.
    @discardableResult
    static func noteKey(_ key: Int32, isPress: Bool, mods: Int32) -> Bool {
        let held = key == KeyCode.leftControl || key == KeyCode.rightControl
            ? isPress
            : KeyMods.contains(mods, KeyMods.control)
        return set(held)
    }

    /// From a press, whose modifiers are the state at the press.
    @discardableResult
    static func notePress(mods: Int32) -> Bool {
        set(KeyMods.contains(mods, KeyMods.control))
    }

    /// The pointer left the window; see the type's note.
    @discardableResult
    static func clear() -> Bool { set(false) }

    private static func set(_ held: Bool) -> Bool {
        guard held != control else { return false }
        control = held
        return true
    }
}
