import Foundation

// GLFW-compatible key / mod / action codes (see canvas `key_codes.hpp` and
// glfw3.h). LavaUI apps can match these without depending on GLFW headers.

/// Physical key codes (GLFW numbering).
public enum KeyCode {
    /// The space bar.
    public static let space: Int32 = 32
    /// The `'` key.
    public static let apostrophe: Int32 = 39
    /// The `,` key.
    public static let comma: Int32 = 44
    /// The `-` key.
    public static let minus: Int32 = 45
    /// The `.` key.
    public static let period: Int32 = 46
    /// The `/` key.
    public static let slash: Int32 = 47
    /// The `0` key on the main row. The other digits follow on: `key0 + n`.
    public static let key0: Int32 = 48
    /// The `1` key on the main row.
    public static let key1: Int32 = 49
    /// The `=` key.
    public static let equal: Int32 = 61
    /// The A key. Letter keys are their uppercase ASCII codes, so `a + n` is the nth letter.
    public static let a: Int32 = 65
    /// The C key.
    public static let c: Int32 = 67
    /// The D key.
    public static let d: Int32 = 68
    /// The F key.
    public static let f: Int32 = 70
    /// The G key.
    public static let g: Int32 = 71
    /// The H key.
    public static let h: Int32 = 72
    /// The L key.
    public static let l: Int32 = 76
    /// The N key.
    public static let n: Int32 = 78
    /// The O key.
    public static let o: Int32 = 79
    /// The P key.
    public static let p: Int32 = 80
    /// The Q key.
    public static let q: Int32 = 81
    /// The R key.
    public static let r: Int32 = 82
    /// The S key.
    public static let s: Int32 = 83
    /// The T key.
    public static let t: Int32 = 84
    /// The V key.
    public static let v: Int32 = 86
    /// The W key.
    public static let w: Int32 = 87
    /// The X key.
    public static let x: Int32 = 88
    /// The Y key.
    public static let y: Int32 = 89
    /// The Z key.
    public static let z: Int32 = 90
    /// Escape.
    public static let escape: Int32 = 256
    /// Enter (Return).
    public static let enter: Int32 = 257
    /// Tab.
    public static let tab: Int32 = 258
    /// Backspace.
    public static let backspace: Int32 = 259
    /// Delete (forward delete).
    public static let delete: Int32 = 261
    /// End.
    public static let end: Int32 = 269
    /// Home.
    public static let home: Int32 = 268
    /// Right arrow.
    public static let right: Int32 = 262
    /// Left arrow.
    public static let left: Int32 = 263
    /// Down arrow.
    public static let down: Int32 = 264
    /// Up arrow.
    public static let up: Int32 = 265
    /// GLFW `PAGE_UP` / `PAGE_DOWN`. Terminals send CSI 5~/6~ for these —
    /// without the mapping, tmux never sees Ctrl+b then PageUp as a scroll.
    public static let pageUp: Int32 = 266
    /// Page Down. See `pageUp`.
    public static let pageDown: Int32 = 267
    /// Insert.
    public static let insert: Int32 = 260
    /// F1–F12 are 290–301 in GLFW, and so here.
    public static func function(_ n: Int32) -> Int32 { 289 + n }
    /// F2. Same as `function(2)`.
    public static let f2: Int32 = 291
    /// Keypad 0. Keypad digits follow on: `kp0 + n`.
    public static let kp0: Int32 = 320
    /// Keypad `-`.
    public static let kpSub: Int32 = 333
    /// Keypad `+`.
    public static let kpAdd: Int32 = 334
    /// Left Shift.
    public static let leftShift: Int32 = 340
    /// Left Control.
    public static let leftControl: Int32 = 341
    /// Left Alt.
    public static let leftAlt: Int32 = 342
    /// Left Super (the Windows key).
    public static let leftSuper: Int32 = 343
    /// Right Shift.
    public static let rightShift: Int32 = 344
    /// Right Control.
    public static let rightControl: Int32 = 345
    /// Right Alt.
    public static let rightAlt: Int32 = 346
    /// Right Super.
    public static let rightSuper: Int32 = 347

    /// Whether `key` is Control, Alt or Super on either side — the modifiers a
    /// shortcut is held with. Shift is not one of them.
    public static func isHoldModifier(_ key: Int32) -> Bool {
        key == leftControl || key == rightControl
            || key == leftAlt || key == rightAlt
            || key == leftSuper || key == rightSuper
    }
}

/// Which mouse button an event came from.
///
/// The order the compositor forwards them in, which is evdev's `BTN_LEFT`,
/// `BTN_RIGHT`, `BTN_MIDDLE` shifted to zero — and the same numbering GLFW
/// uses, which is what the windowed path was written against. Middle is 2, not
/// 1, and that is the one worth having a name for.
public enum PointerButton {
    /// The primary button.
    public static let left: Int32 = 0
    /// The secondary button.
    public static let right: Int32 = 1
    /// The middle button (a wheel press).
    public static let middle: Int32 = 2
}

/// Modifier bitfield (GLFW `mods`).
public enum KeyMods {
    /// Shift is held.
    public static let shift: Int32 = 0x0001
    /// Control is held.
    public static let control: Int32 = 0x0002
    /// Alt is held.
    public static let alt: Int32 = 0x0004
    /// Super (the Windows key) is held.
    public static let superKey: Int32 = 0x0008

    /// Whether `mods` has `flag` set.
    public static func contains(_ mods: Int32, _ flag: Int32) -> Bool {
        (mods & flag) != 0
    }

    /// Whether both Control and Shift are held.
    public static func controlShift(_ mods: Int32) -> Bool {
        contains(mods, control) && contains(mods, shift)
    }
}

/// Key action (GLFW). Packaged as `Float` in `InputEvent.x` for Key events.
public enum KeyAction {
    /// The key was released.
    public static let release: Float = 0
    /// The key was pressed.
    public static let press: Float = 1
    /// The key is held and auto-repeating.
    public static let `repeat`: Float = 2

    /// Whether the action is a press or a repeat, that is, the key is down.
    public static func isDown(_ action: Float) -> Bool {
        action == press || action == `repeat`
    }
}

/// Mirrors `canvas::InputEventKind`.
public enum InputEventKind: UInt32, Sendable, Equatable {
    /// No event; what a poll returns when the queue is empty.
    case none = 0
    /// `x`/`y` = window position, `button` = which button, `mods` = held
    /// modifier keys (see `InputEvent.mods`).
    case mouseDown = 1
    /// A button was released. `x`/`y` = window position, `button` = which button.
    case mouseUp = 2
    /// The pointer moved. `x`/`y` = window position.
    case mouseMove = 3
    /// Framebuffer size changed; `x`/`y` are new width/height.
    case resize = 4
    /// Keyboard; `button` = key, `x` = action, `y` = mods.
    case key = 5
    /// A committed character; `button` holds the Unicode scalar. Distinct from
    /// `key`, which is physical and says nothing about layout or dead keys.
    case text = 6
    /// Wheel / trackpad; `x`/`y` are deltas in notches, `button` holds mods.
    case scroll = 7
    /// Window needs a redraw (expose, un-minimize, compositor damage).
    case refresh = 8
    /// Files dropped on the window. `x`/`y` = cursor position, `button` =
    /// path count; the paths themselves come from `Editor.droppedFile(at:)`
    /// while handling this event — the next drop overwrites them.
    case fileDrop = 9
    /// A scene node the renderer owns has moved. `button` = node id, `x`/`y`
    /// = its scroll offset.
    ///
    /// The read path for renderer-owned state: the *decision* to scroll never
    /// reaches this process, which is what lets it happen while this process
    /// is stopped, but the *result* comes back — because a list that does not
    /// know which rows are on screen cannot virtualize.
    ///
    /// Coalesced per node, so an animating scroll costs one event per frame
    /// rather than one per step. Ignoring it entirely is fine and obliges
    /// nothing.
    case nodeScroll = 10
    /// A node finished the animation this process declared for it.
    /// `button` = node id.
    ///
    /// The other half of declaring a target: having said "move there" and
    /// stopped thinking about it, this is the only way to learn it arrived.
    /// Sequencing one transition after another is the ordinary reason to
    /// want that — a timer here would be a second copy of the renderer's
    /// clock, running in a process that may not be scheduled when it
    /// matters.
    case nodeAnimationDone = 11
    /// The node under the pointer changed. `button` = node id, 0 for none.
    ///
    /// The renderer hit-tests to draw its tints, so it already knows. Without
    /// this the app would hit-test the same geometry again from coordinates —
    /// and get it wrong for any node the renderer has scrolled or animated,
    /// since that node is no longer where the app declared it.
    ///
    /// A click is this plus the `.mouseDown` queued immediately after it.
    case nodeHover = 12
    /// The pointer left this window. No payload — see `PointerLeave` in
    /// `draw_command.hpp`.
    case pointerLeave = 13
    /// The window was maximized or restored. `button` = 1 maximized, 0
    /// restored. See `WindowState` in `draw_command.hpp`.
    case windowState = 14
    /// A drag offering files is over this window at `x`/`y`. See `DragOver`
    /// in `draw_command.hpp` — and `View.onDrop(targeted:springLoaded:perform:)`,
    /// which is what it drives.
    case dragOver = 15
    /// The drag left this window, or ended anywhere. No payload.
    case dragLeave = 16
}

/// One polled event from `Editor.pollInputEvent`.
public struct InputEvent: Sendable, Equatable {
    /// What happened; decides how the other fields read.
    public var kind: InputEventKind
    /// First payload value. Its meaning depends on `kind`.
    public var x: Float
    /// Second payload value. Its meaning depends on `kind`.
    public var y: Float
    /// Integer payload. Its meaning depends on `kind`.
    public var button: Int32
    /// GLFW modifier bitfield (see `KeyMods`). Only populated for
    /// `.mouseDown`/`.mouseUp` — `.scroll` already carries mods in `button`,
    /// `.key` carries them in `y`.
    public var mods: Int32

    /// Creates an event.
    public init(kind: InputEventKind, x: Float, y: Float, button: Int32, mods: Int32 = 0) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.mods = mods
    }

    /// For a `.key` event, the key code (`KeyCode`).
    public var keyCode: Int32 { button }
    /// For a `.key` event, the action (`KeyAction`).
    public var keyAction: Float { x }
    /// For a `.key` event, the modifier bits (`KeyMods`).
    public var keyMods: Int32 { Int32(y) }
}

// MARK: - Content scale shortcuts

/// Default chord: Ctrl+Shift + `=` / `-` / `0` (and numpad).
///
/// Library helper — apps can call this from their event loop, or roll their own
/// binding to `FontStore.zoomIn/Out`.
public enum ContentScaleShortcuts {
    /// Applies a key event to `FontStore` scale if it matches the default chord.
    /// Returns `true` when the active face size changed (caller should dirty layout).
    @discardableResult
    public static func handle(
        key: Int32,
        action: Float,
        mods: Int32,
        editor: Editor
    ) -> Bool {
        guard KeyAction.isDown(action), KeyMods.controlShift(mods) else {
            return false
        }
        if key == KeyCode.equal || key == KeyCode.kpAdd {
            return FontStore.zoomIn(into: editor)
        }
        if key == KeyCode.minus || key == KeyCode.kpSub {
            return FontStore.zoomOut(into: editor)
        }
        if key == KeyCode.key0 || key == KeyCode.kp0 {
            return FontStore.resetScale(into: editor)
        }
        return false
    }

    /// Convenience over a polled `InputEvent`.
    @discardableResult
    public static func handle(_ event: InputEvent, editor: Editor) -> Bool {
        guard event.kind == .key else { return false }
        return handle(
            key: event.keyCode,
            action: event.keyAction,
            mods: event.keyMods,
            editor: editor
        )
    }
}
