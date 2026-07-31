import Foundation

// GLFW-compatible key / mod / action codes (see canvas `key_codes.hpp` and
// glfw3.h). LavaUI apps can match these without depending on GLFW headers.

/// Physical key codes (GLFW numbering).
public enum KeyCode {
    public static let space: Int32 = 32
    public static let apostrophe: Int32 = 39
    public static let comma: Int32 = 44
    public static let minus: Int32 = 45
    public static let period: Int32 = 46
    public static let slash: Int32 = 47
    public static let key0: Int32 = 48
    public static let key1: Int32 = 49
    public static let equal: Int32 = 61
    public static let a: Int32 = 65
    public static let c: Int32 = 67
    public static let v: Int32 = 86
    public static let x: Int32 = 88
    public static let y: Int32 = 89
    public static let z: Int32 = 90
    public static let d: Int32 = 68
    public static let s: Int32 = 83
    public static let w: Int32 = 87
    public static let escape: Int32 = 256
    public static let enter: Int32 = 257
    public static let tab: Int32 = 258
    public static let backspace: Int32 = 259
    public static let delete: Int32 = 261
    public static let end: Int32 = 269
    public static let home: Int32 = 268
    public static let right: Int32 = 262
    public static let left: Int32 = 263
    public static let down: Int32 = 264
    public static let up: Int32 = 265
    public static let kp0: Int32 = 320
    public static let kpSub: Int32 = 333
    public static let kpAdd: Int32 = 334
    public static let leftShift: Int32 = 340
    public static let leftControl: Int32 = 341
    public static let leftAlt: Int32 = 342
}

/// Modifier bitfield (GLFW `mods`).
public enum KeyMods {
    public static let shift: Int32 = 0x0001
    public static let control: Int32 = 0x0002
    public static let alt: Int32 = 0x0004
    public static let superKey: Int32 = 0x0008

    public static func contains(_ mods: Int32, _ flag: Int32) -> Bool {
        (mods & flag) != 0
    }

    public static func controlShift(_ mods: Int32) -> Bool {
        contains(mods, control) && contains(mods, shift)
    }
}

/// Key action (GLFW). Packaged as `Float` in `InputEvent.x` for Key events.
public enum KeyAction {
    public static let release: Float = 0
    public static let press: Float = 1
    public static let `repeat`: Float = 2

    public static func isDown(_ action: Float) -> Bool {
        action == press || action == `repeat`
    }
}

/// Mirrors `canvas::InputEventKind`.
public enum InputEventKind: UInt32, Sendable, Equatable {
    case none = 0
    /// `x`/`y` = window position, `button` = which button, `mods` = held
    /// modifier keys (see `InputEvent.mods`).
    case mouseDown = 1
    case mouseUp = 2
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
}

/// One polled event from `Editor.pollInputEvent`.
public struct InputEvent: Sendable, Equatable {
    public var kind: InputEventKind
    public var x: Float
    public var y: Float
    public var button: Int32
    /// GLFW modifier bitfield (see `KeyMods`). Only populated for
    /// `.mouseDown`/`.mouseUp` — `.scroll` already carries mods in `button`,
    /// `.key` carries them in `y`.
    public var mods: Int32

    public init(kind: InputEventKind, x: Float, y: Float, button: Int32, mods: Int32 = 0) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.mods = mods
    }

    public var keyCode: Int32 { button }
    public var keyAction: Float { x }
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
