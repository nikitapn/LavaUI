import SwiftCrossUI
import Foundation

#if canImport(GtkBackend)
    import CGtk
    import Gtk
    import GtkBackend
    #if canImport(Glibc)
        import Glibc
    #endif
#endif

/// Screen-space rectangle in pixels (origin top-left of the display).
public struct ScreenRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Events from the layout slot that drive the overlay canvas.
public enum CanvasSlotEvent: Sendable {
    /// Slot's screen geometry changed (move/resize of host or layout).
    case frameChanged(ScreenRect)
    /// Host toplevel is mapped and not minimized (false → hide canvas).
    case hostActive(Bool)
}

/// Reserves a flexible region in the SwiftCrossUI layout and reports its
/// on-screen frame + host window activity so a borderless GLFW canvas can
/// track it (or hide while the host moves/minimizes).
public struct CanvasLayoutSlot: View {
    var minWidth: Double
    var minHeight: Double
    /// When true, show an explicit "paused" label in the slot while the
    /// live canvas is hidden during host interaction.
    var showPausedChrome: Bool
    var onEvent: (CanvasSlotEvent) -> Void

    public init(
        minWidth: Double = 320,
        minHeight: Double = 200,
        showPausedChrome: Bool = true,
        onEvent: @escaping (CanvasSlotEvent) -> Void = { _ in }
    ) {
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.showPausedChrome = showPausedChrome
        self.onEvent = onEvent
    }

    public var body: some View {
        #if canImport(GtkBackend)
            ZStack {
                GtkCanvasSlotHost(minWidth: minWidth, minHeight: minHeight, onEvent: onEvent)
                if showPausedChrome {
                    // Visible whenever the GLFW surface is hidden (move/resize/
                    // minimize). While the canvas is live it covers this.
                    VStack {
                        Text("Canvas paused")
                        Text("(moving / resizing host)")
                    }
                    .padding()
                }
            }
            .frame(minWidth: minWidth, minHeight: minHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16))
        #else
            Color(red: 0.12, green: 0.13, blue: 0.16)
                .frame(minWidth: minWidth, minHeight: minHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

#if canImport(GtkBackend)
    struct GtkCanvasSlotHost: GtkWidgetRepresentable {
        var minWidth: Double
        var minHeight: Double
        var onEvent: (CanvasSlotEvent) -> Void

        final class Coordinator {
            var onEvent: (CanvasSlotEvent) -> Void = { _ in }
            var lastFrame: ScreenRect?
            var lastHostActive: Bool?
            var pollSource: UInt32 = 0
            var widgetPointer: UnsafeMutablePointer<GtkWidget>?

            func startPolling() {
                stopPolling()
                let retained = Unmanaged.passRetained(self).toOpaque()
                pollSource = g_timeout_add_full(
                    G_PRIORITY_DEFAULT_IDLE,
                    33,
                    { raw in
                        let coord = Unmanaged<Coordinator>.fromOpaque(raw!).takeUnretainedValue()
                        coord.poll()
                        return 1 // G_SOURCE_CONTINUE
                    },
                    retained,
                    { raw in
                        Unmanaged<Coordinator>.fromOpaque(raw!).release()
                    }
                )
            }

            func stopPolling() {
                if pollSource != 0 {
                    g_source_remove(pollSource)
                    pollSource = 0
                }
            }

            func poll() {
                guard let widget = widgetPointer else { return }

                let active = Self.hostIsActive(widget: widget)
                if lastHostActive != active {
                    lastHostActive = active
                    onEvent(.hostActive(active))
                }

                // No need for geometry while minimized — canvas should stay hidden.
                guard active else { return }

                guard let frame = Self.screenFrame(widget: widget) else { return }
                if lastFrame != frame {
                    lastFrame = frame
                    onEvent(.frameChanged(frame))
                }
            }

            /// False when the Gtk toplevel is minimized, unmapped, or withdrawn.
            static func hostIsActive(widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
                guard gtk_widget_get_mapped(widget) != 0 else { return false }
                guard let native = gtk_widget_get_native(widget) else { return false }
                guard let surface = gtk_native_get_surface(native) else { return false }

                if gdk_surface_get_mapped(surface) == 0 {
                    return false
                }

                // Prefer GdkToplevel state when available.
                // From gdkenums.h:
                //   MINIMIZED = 1<<6, SUSPENDED = 1<<8  (values vary by GTK minor;
                //   also check common aliases via full bit probe below).
                let rtldDefault = UnsafeMutableRawPointer(bitPattern: Int(bitPattern: UInt(0)))
                if let sym = dlsym(rtldDefault, "gdk_toplevel_get_state") {
                    typealias ToplevelStateFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
                    let toplevelGetState = unsafeBitCast(sym, to: ToplevelStateFn.self)
                    let state = toplevelGetState(UnsafeMutableRawPointer(surface))
                    // Hide on any "not really on-screen" bits we know about.
                    let hideMask: UInt32 =
                        (1 << 5) | // FULLSCREEN sometimes paired — skip
                        (1 << 6) | // MINIMIZED
                        (1 << 8)   // SUSPENDED
                    // Only treat MINIMIZED (bit 6) and SUSPENDED (bit 8) as inactive.
                    if state & ((1 << 6) | (1 << 8)) != 0 {
                        return false
                    }
                    _ = hideMask
                }

                // X11 fallback: _NET_WM_STATE_HIDDEN is set when iconified.
                if x11SurfaceIsHidden(surface) {
                    return false
                }
                return true
            }

            static func x11SurfaceIsHidden(_ surface: OpaquePointer) -> Bool {
                let rtldDefault = UnsafeMutableRawPointer(bitPattern: Int(bitPattern: UInt(0)))
                guard
                    let xidSym = dlsym(rtldDefault, "gdk_x11_surface_get_xid"),
                    let dpySym = dlsym(rtldDefault, "gdk_x11_display_get_xdisplay"),
                    let internSym = dlsym(rtldDefault, "XInternAtom"),
                    let getPropSym = dlsym(rtldDefault, "XGetWindowProperty"),
                    let freeSym = dlsym(rtldDefault, "XFree")
                else { return false }

                typealias XidFn = @convention(c) (OpaquePointer?) -> UInt
                typealias DpyFn = @convention(c) (OpaquePointer?) -> OpaquePointer?
                typealias InternFn = @convention(c) (
                    OpaquePointer?, UnsafePointer<CChar>?, Int32
                ) -> UInt
                typealias GetPropFn = @convention(c) (
                    OpaquePointer?, UInt, UInt, Int, Int, Int32, UInt,
                    UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<Int32>?,
                    UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<UInt>?,
                    UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
                ) -> Int32
                typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

                let getXid = unsafeBitCast(xidSym, to: XidFn.self)
                let getDpy = unsafeBitCast(dpySym, to: DpyFn.self)
                let intern = unsafeBitCast(internSym, to: InternFn.self)
                let getProp = unsafeBitCast(getPropSym, to: GetPropFn.self)
                let xFree = unsafeBitCast(freeSym, to: FreeFn.self)

                let display = gdk_surface_get_display(surface)
                guard let xdisplay = getDpy(display) else { return false }
                let xid = getXid(surface)
                if xid == 0 { return false }

                let wmState = intern(xdisplay, "_NET_WM_STATE", 1 /* True */)
                let hidden = intern(xdisplay, "_NET_WM_STATE_HIDDEN", 1)

                var actualType: UInt = 0
                var actualFormat: Int32 = 0
                var nitems: UInt = 0
                var bytesAfter: UInt = 0
                var prop: UnsafeMutablePointer<UInt8>?
                let status = getProp(
                    xdisplay, xid, wmState, 0, 1024, 0 /* False */,
                    0 /* AnyPropertyType */,
                    &actualType, &actualFormat, &nitems, &bytesAfter, &prop
                )
                defer { if let prop { _ = xFree(prop) } }
                // Success == 0 (Success)
                guard status == 0, let prop, nitems > 0, actualFormat == 32 else {
                    return false
                }
                let atoms = UnsafeRawPointer(prop).bindMemory(to: UInt.self, capacity: Int(nitems))
                for i in 0..<Int(nitems) {
                    if atoms[i] == hidden { return true }
                }
                return false
            }

            static func screenFrame(widget: UnsafeMutablePointer<GtkWidget>) -> ScreenRect? {
                guard let rootOpaque = gtk_widget_get_root(widget) else { return nil }
                let rootWidget = UnsafeMutableRawPointer(rootOpaque).assumingMemoryBound(to: GtkWidget.self)

                var localX: Double = 0
                var localY: Double = 0
                if gtk_widget_translate_coordinates(
                    widget, rootWidget, 0, 0, &localX, &localY
                ) == 0 {
                    return nil
                }

                let w = max(1, Int(gtk_widget_get_width(widget)))
                let h = max(1, Int(gtk_widget_get_height(widget)))
                if w <= 1 && h <= 1 {
                    return nil
                }

                guard let native = gtk_widget_get_native(widget) else { return nil }
                guard let surface = gtk_native_get_surface(native) else { return nil }

                let scale = max(1, Int(gdk_surface_get_scale_factor(surface)))

                var surfaceRootX = 0
                var surfaceRootY = 0
                if !x11SurfaceRootOrigin(surface, x: &surfaceRootX, y: &surfaceRootY) {
                    var nx: Double = 0
                    var ny: Double = 0
                    gtk_native_get_surface_transform(native, &nx, &ny)
                    surfaceRootX = Int(nx.rounded())
                    surfaceRootY = Int(ny.rounded())
                }

                let x = surfaceRootX + Int((localX * Double(scale)).rounded())
                let y = surfaceRootY + Int((localY * Double(scale)).rounded())
                return ScreenRect(x: x, y: y, width: w * scale, height: h * scale)
            }

            static func x11SurfaceRootOrigin(
                _ surface: OpaquePointer,
                x: inout Int,
                y: inout Int
            ) -> Bool {
                let rtldDefault = UnsafeMutableRawPointer(bitPattern: Int(bitPattern: UInt(0)))
                guard let xidSym = dlsym(rtldDefault, "gdk_x11_surface_get_xid"),
                      let dpySym = dlsym(rtldDefault, "gdk_x11_display_get_xdisplay"),
                      let trSym = dlsym(rtldDefault, "XTranslateCoordinates"),
                      let rootSym = dlsym(rtldDefault, "XDefaultRootWindow")
                else {
                    return false
                }

                typealias XidFn = @convention(c) (OpaquePointer?) -> UInt
                typealias DpyFn = @convention(c) (OpaquePointer?) -> OpaquePointer?
                typealias XTranslateFn = @convention(c) (
                    OpaquePointer?, UInt, UInt, Int32, Int32,
                    UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                    UnsafeMutablePointer<UInt>?
                ) -> Int32
                typealias XRootFn = @convention(c) (OpaquePointer?) -> UInt

                let getXid = unsafeBitCast(xidSym, to: XidFn.self)
                let getDpy = unsafeBitCast(dpySym, to: DpyFn.self)
                let translate = unsafeBitCast(trSym, to: XTranslateFn.self)
                let defaultRoot = unsafeBitCast(rootSym, to: XRootFn.self)

                let display = gdk_surface_get_display(surface)
                guard let xdisplay = getDpy(display) else { return false }
                let xid = getXid(surface)
                if xid == 0 { return false }

                var rx: Int32 = 0
                var ry: Int32 = 0
                var child: UInt = 0
                let root = defaultRoot(xdisplay)
                guard translate(xdisplay, xid, root, 0, 0, &rx, &ry, &child) != 0 else {
                    return false
                }
                x = Int(rx)
                y = Int(ry)
                return true
            }
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
            var css = box.css
            css.set(property: .backgroundColor(Gtk.Color(0.08, 0.09, 0.12)))
            box.css = css

            let coord = context.coordinator
            coord.widgetPointer = box.widgetPointer
            coord.onEvent = onEvent
            coord.startPolling()
            return box
        }

        func updateGtkWidget(_ box: Gtk.Box, context: Context) {
            context.coordinator.widgetPointer = box.widgetPointer
            context.coordinator.onEvent = onEvent
            if context.coordinator.pollSource == 0 {
                context.coordinator.startPolling()
            }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            gtkWidget: Gtk.Box,
            context: Context
        ) -> ViewSize {
            let w = max(minWidth, proposal.width ?? minWidth)
            let h = max(minHeight, proposal.height ?? minHeight)
            return ViewSize(w, h)
        }
    }
#endif
