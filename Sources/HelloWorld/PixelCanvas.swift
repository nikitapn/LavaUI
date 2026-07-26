import SwiftCrossUI
import ImageFormats

#if canImport(GtkBackend)
    import Gtk
    import GtkBackend
#endif

/// Raw pointer input captured over a ``PixelCanvas``, in canvas-local pixel
/// coordinates (origin top-left, matching the pixel buffer you supplied).
public enum CanvasInputEvent {
    case pointerMoved(x: Double, y: Double)
    case pointerExited
    case mouseDown(button: UInt, x: Double, y: Double)
    case mouseUp(button: UInt, x: Double, y: Double)
}

/// Displays a raw RGBA pixel buffer (e.g. read back from an offscreen
/// Vulkan/Dear ImGui render target) and reports raw pointer input over it.
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
///
/// - Parameters:
///   - width: Width of `pixels`, in pixels.
///   - height: Height of `pixels`, in pixels.
///   - pixels: Tightly packed RGBA8 bytes, row-major, `width * height * 4`
///     bytes long.
///   - onEvent: Called for every pointer event captured over the canvas.
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
    /// An invisible Gtk widget that exists purely to capture raw pointer
    /// events over whatever it's stacked on top of.
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

            let coordinator = context.coordinator

            let motion = Gtk.EventControllerMotion()
            motion.motion = { _, x, y in
                coordinator.onEvent(.pointerMoved(x: x, y: y))
            }
            motion.leave = { _ in
                coordinator.onEvent(.pointerExited)
            }
            box.addEventController(motion)

            // Note: only responds to the primary button for now. GestureSingle's
            // `button` property (0 = "any button") hits a bug in the vendored
            // Gtk wrapper's GObjectProperty setter for UInt properties, so we
            // leave it at its default rather than fight that here.
            let click = Gtk.GestureClick()
            click.pressed = { gesture, _, x, y in
                coordinator.onEvent(.mouseDown(button: gesture.button, x: x, y: y))
            }
            click.released = { gesture, _, x, y in
                coordinator.onEvent(.mouseUp(button: gesture.button, x: x, y: y))
            }
            box.addEventController(click)

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
    }
#endif
