import SwiftCrossUI
import ImageFormats

#if canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend
#endif

/// Raw pointer/keyboard input captured over a ``PixelCanvas``, in
/// canvas-local pixel coordinates (origin top-left, matching the pixel
/// buffer you supplied).
public enum CanvasInputEvent {
    case pointerMoved(x: Double, y: Double)
    case pointerExited
    case mouseDown(button: UInt, x: Double, y: Double)
    case mouseUp(button: UInt, x: Double, y: Double)
    /// GLFW-style key code / action / mods (see `CanvasKey` in CanvasKit).
    case key(key: Int, action: Int, mods: Int)
    /// UTF-8 text committed by the keyboard (printable characters).
    case textInput(String)
}

/// Displays a raw RGBA pixel buffer (e.g. read back from an offscreen
/// Vulkan/Dear ImGui render target) and reports raw pointer + keyboard
/// input over it.
///
/// Pixel display goes through ``SwiftCrossUI/Image``, which already does the
/// right thing on every backend (it's what the framework's own `Image` view
/// uses under the hood). Input capture is the part SwiftCrossUI doesn't have
/// a cross-backend API for yet (no continuous pointer tracking), so that
/// half uses the Gtk-specific ``GtkWidgetRepresentable`` escape hatch. On
/// backends other than Gtk this displays the image but reports no input.
///
/// - Important: Whatever renders `pixels` (your Vulkan/Dear ImGui pipeline)
///   must not block the thread this view's state updates happen on. A
///   render loop that's expensive enough to saturate the main thread will
///   starve Gtk's own event processing and make pointer input feel laggy or
///   unresponsive — do the actual rendering on a background queue and only
///   hop back to hand off the finished pixel buffer.
public struct PixelCanvas: View {
    var width: Int
    var height: Int
    var pixels: [UInt8]
    var onEvent: (CanvasInputEvent) -> Void

    public init(
        width: Int,
        height: Int,
        pixels: [UInt8],
        onEvent: @escaping (CanvasInputEvent) -> Void = { _ in }
    ) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.onEvent = onEvent
    }

    public var body: some View {
        ZStack {
            Image(ImageFormats.Image<RGBA>(width: width, height: height, bytes: pixels))

            #if canImport(GtkBackend)
                GtkPointerCapture(onEvent: onEvent)
            #endif
        }
        .frame(width: Double(width), height: Double(height))
    }
}

#if canImport(GtkBackend)
    /// An invisible Gtk widget that captures pointer and keyboard events
    /// over whatever it's stacked on top of.
    struct GtkPointerCapture: GtkWidgetRepresentable {
        var onEvent: (CanvasInputEvent) -> Void

        final class Coordinator {
            var onEvent: (CanvasInputEvent) -> Void = { _ in }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeGtkWidget(context: Context) -> Gtk.Box {
            let box = Gtk.Box()
            box.expandHorizontally = true
            box.useExpandHorizontally = true
            box.expandVertically = true
            box.useExpandVertically = true

            // Allow the overlay to take keyboard focus after a click so
            // EventControllerKey receives key events.
            gtk_widget_set_focusable(box.widgetPointer, 1)
            gtk_widget_set_can_focus(box.widgetPointer, 1)

            let coordinator = context.coordinator

            let motion = Gtk.EventControllerMotion()
            motion.motion = { _, x, y in
                coordinator.onEvent(.pointerMoved(x: x, y: y))
            }
            motion.leave = { _ in
                coordinator.onEvent(.pointerExited)
            }
            box.addEventController(motion)

            let click = Gtk.GestureClick()
            click.pressed = { gesture, _, x, y in
                coordinator.onEvent(.mouseDown(button: gesture.button, x: x, y: y))
                gtk_widget_grab_focus(box.widgetPointer)
            }
            click.released = { gesture, _, x, y in
                coordinator.onEvent(.mouseUp(button: gesture.button, x: x, y: y))
            }
            box.addEventController(click)

            let key = Gtk.EventControllerKey()
            key.keyPressed = { _, keyval, _, state in
                let mods = Self.mods(from: state)
                if let canvasKey = Self.canvasKey(from: keyval) {
                    coordinator.onEvent(.key(key: canvasKey, action: 1, mods: mods))
                }
                // Printable Latin-1 → text input (covers ST/expressions).
                if keyval >= 32 && keyval < 127, mods & 2 == 0 {
                    if let scalar = UnicodeScalar(UInt32(keyval)) {
                        coordinator.onEvent(.textInput(String(Character(scalar))))
                    }
                }
            }
            key.keyReleased = { _, keyval, _, state in
                let mods = Self.mods(from: state)
                if let canvasKey = Self.canvasKey(from: keyval) {
                    coordinator.onEvent(.key(key: canvasKey, action: 0, mods: mods))
                }
            }
            box.addEventController(key)

            return box
        }

        func updateGtkWidget(_ box: Gtk.Box, context: Context) {
            context.coordinator.onEvent = onEvent
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            gtkWidget: Gtk.Box,
            context: Context
        ) -> ViewSize {
            ViewSize(proposal.width ?? 0, proposal.height ?? 0)
        }

        private static func mods(from state: GdkModifierType) -> Int {
            var mods = 0
            let raw = UInt(state.rawValue)
            if raw & UInt(GDK_SHIFT_MASK.rawValue) != 0 { mods |= 1 }
            if raw & UInt(GDK_CONTROL_MASK.rawValue) != 0 { mods |= 2 }
            if raw & UInt(GDK_ALT_MASK.rawValue) != 0 { mods |= 4 }
            return mods
        }

        /// Maps a GDK keyval to a GLFW-style key code.
        private static func canvasKey(from keyval: UInt) -> Int? {
            switch keyval {
            case 0xff0d, 0xff8d: return 257 // Return / KP_Enter
            case 0xff08: return 259 // BackSpace
            case 0xffff: return 261 // Delete
            case 0xff09: return 258 // Tab
            case 0xff1b: return 256 // Escape
            case 0xff51: return 263 // Left
            case 0xff52: return 265 // Up
            case 0xff53: return 262 // Right
            case 0xff54: return 264 // Down
            case 0xff50: return 268 // Home
            case 0xff57: return 269 // End
            case 0xff55: return 266 // Page_Up
            case 0xff56: return 267 // Page_Down
            case 0xffe1, 0xffe2: return 340 // Shift
            case 0xffe3, 0xffe4: return 341 // Control
            case 0xffe9, 0xffea: return 342 // Alt
            default:
                if keyval >= 32 && keyval < 127 {
                    // GLFW letter keys are uppercase.
                    if keyval >= 97 && keyval <= 122 {
                        return Int(keyval - 32)
                    }
                    return Int(keyval)
                }
                return nil
            }
        }
    }
#endif
