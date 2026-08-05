#if canImport(CxxCanvas)
import CxxCanvas
import CanvasResources
import Foundation
import LavaUI
#if canImport(LavaIDL)
import LavaClient
import LavaIDL
import NPRPC
#endif

// One renderer process, several app processes, one shared arena each.
//
//   terminal 1:  swift run -c release ArenaDemo host
//   terminal 2:  swift run -c release ArenaDemo produce alpha
//   terminal 3:  swift run -c release ArenaDemo produce beta
//
// The host opens one window of its own — the compositor's, listing who is
// connected — and one more per client that asks for a surface. Each client
// gets its own window, its own arena and its own input stream; none of them
// knows the others exist.
//
// The producer owns no GPU, no window and no Vulkan. It shapes text with
// HarfBuzz — which is why `canvas::Font` deliberately "doesn't know Vulkan
// exists" — writes draw commands straight into shared memory, and publishes.
// The renderer maps the same memory and draws it. Nothing is copied on either
// side of the boundary: the bytes the producer writes are the bytes the
// renderer reads.
//
// The control plane is NPRPC over shared memory (`idl/lava.npidl`): the app
// asks the renderer to name a font, hands it the arena to read, and tells it
// when a frame is ready. That last call is `[unreliable]` — fire and forget —
// which is what lets the renderer *block* instead of polling: a shared-memory
// store wakes nobody, so without a nudge the renderer has no way to learn a
// frame arrived.
//
// Input comes back the other way, over the same interface: the renderer owns
// the window, so it owns the mouse and the keyboard, and `SubscribeInput` is
// how a process with neither finds out that the pointer moved or that its
// surface changed size. The producer below hit-tests its own bars from
// coordinates it was told — the renderer forwards events and interprets none
// of them.
//
// Built without nprpc checked out, both halves still run: the font id falls
// back to a convention and the renderer polls. That fallback is what this
// looked like before the control plane existed.

let mode = CommandLine.arguments.dropFirst().first ?? "host"

/// A label for this client, so several running at once are distinguishable —
/// it titles the window and names the arena.
let clientName = CommandLine.arguments.dropFirst(2).first ?? "demo"

#if canImport(LavaIDL)
/// Namespaced by pid, because `DrawArena.create` refuses an id that already
/// exists — which is the right refusal, and exactly what two clients of the
/// same compositor would hit if the id were a constant.
let arenaID = "\(clientName)-\(getpid())"
#else
/// Without a control plane the renderer polls for one well-known arena, so
/// the id has to be the one it is looking for.
let arenaID = "demo"
#endif

let fontPath = (LavaResources.fontsDirectory as NSString)
    .appendingPathComponent("OpenSans-Regular.ttf")
let fontPixelSize: Float = 20

/// Font id the producer stamps into every `GlyphInstance`.
///
/// Answered by `Compositor.RegisterFont` when the control plane is available.
/// The fallback is the convention this demo used before that existed: the
/// renderer registers this face first, so it lands at 0.
nonisolated(unsafe) var sharedFontID: UInt32 = 0

// ─── Renderer ────────────────────────────────────────────────────────────────

func runHost() {
    // The compositor's own window, and the only one it opens for itself. It
    // outlives every client, which is what keeps the device and the event
    // loop alive across a desktop where every app has quit — and it gives
    // "which clients are connected" somewhere to be answered.
    guard let editor = Editor.open(
        assetsRoot: CanvasResources.engineRoot,
        width: 560, height: 300,
        title: "LavaUI compositor"
    ) else {
        FileHandle.standardError.write(Data("failed to open the window\n".utf8))
        exit(1)
    }

#if canImport(LavaIDL)
    // Both the font id and the arena now arrive over RPC, so the renderer
    // registers nothing up front and waits to be told.
    LoopQueue.loopThread = Thread.current
    LoopQueue.wake = { [editor] in editor.wakeEventLoop() }
    // LavaUI's own resources, not the engine tree — the compositor's window is
    // drawn by this process through the ordinary in-process path, so it needs
    // the same face any LavaUI app would use.
    if FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor) == nil {
        FileHandle.standardError.write(
            Data("warning: no UI face — the compositor window will be blank\n".utf8)
        )
    }
    let rootList = DrawList(editor: editor, window: .main)

    do {
        rpcRuntime = try startCompositorService(editor: editor)
    } catch {
        FileHandle.standardError.write(Data("control plane failed: \(error)\n".utf8))
        exit(1)
    }

    var lastLagReport = Date.distantPast
    var lastStatus: [String] = []
    while editor.isOpen {
        // Blocks until something happens: input, or a client's `Present`
        // waking us through `LoopQueue`/`wakeEventLoop`. No frame clock, no
        // poll — an idle desktop costs nothing.
        editor.pumpEvents(timeout: -1)

        // Servant work first, and this is where every control-plane call
        // actually runs — the POA posts here and the wake above is what got us
        // out of `pumpEvents`. A `CreateSurface` that arrived while we were
        // parked belongs to the frame about to be drawn.
        LoopQueue.drain()

        // Input goes to the client that owns the window it happened in, and
        // nowhere else. The renderer interprets none of it — it routes and
        // forwards. Which is the point: the process that owns the window is
        // not the process that knows what a click means.
        for window in editor.windowIDs {
            let surface = SurfaceRegistry.surface(window: window)
            while let event = editor.pollInputEvent(window: window) {
                // Drained even for the compositor's own window, which has no
                // client: an unread queue only grows.
                guard let surface else { continue }
                surface.input.post(event)
                // A resize recreates the swapchain and an expose invalidates
                // what was on screen, so both need a repaint whether or not
                // the client publishes a new frame in response.
                if event.kind == .resize || event.kind == .refresh {
                    SurfaceRegistry.markDirty(surfaceId: surface.id)
                }
            }
        }

        // The titlebar X. On a client's window it ends that client's surface
        // — the input stream stops, which is how the client hears about it.
        for window in editor.windowIDs where editor.windowShouldClose(window) {
            if let surface = SurfaceRegistry.surface(window: window) {
                SurfaceRegistry.destroy(id: surface.id)
            }
        }
        // On the compositor's own window it ends the compositor.
        if editor.windowShouldClose(.main) { break }

        // The renderer's own reason to redraw: a scene node it moved without
        // anyone asking. Nothing was published and no input was queued — a
        // loop driven by those two alone would sit still while the user
        // scrolled.
        for surface in SurfaceRegistry.all
        where editor.takeInternalRepaint(window: surface.window) {
            SurfaceRegistry.markDirty(surfaceId: surface.id)
        }

        // Only what changed. This is what naming the surface in `Present`
        // buys: with ten clients on screen, one publishing a frame costs one
        // repaint rather than ten.
        for window in SurfaceRegistry.takeDirty() {
            editor.renderFrame(window: window)
            // Shown after its first frame, never before — see `Surface.shown`.
            if let surface = SurfaceRegistry.surface(window: window), !surface.shown {
                surface.shown = true
                editor.setVisible(true, window: window)
            }
        }

        let status = compositorStatus()
        if status != lastStatus {
            lastStatus = status
            drawCompositorStatus(editor: editor, list: rootList, lines: status)
            editor.renderFrame(window: .main)
        }

        // What the ack direction buys: a client that has stopped reading is
        // visible from here, and looks nothing like one that is simply idle.
        if Date().timeIntervalSince(lastLagReport) > 1 {
            for surface in SurfaceRegistry.all where surface.input.lag > 64 {
                lastLagReport = Date()
                let line = "surface \(surface.id) (\(surface.title)) is "
                    + "\(surface.input.lag) input events behind\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }
#else
    // No control plane: the pre-RPC behaviour. Register the face first so it
    // lands at the id the producer assumes, and poll for the arena.
    guard let id = editor.registerFont(path: fontPath, pixelSize: fontPixelSize) else {
        FileHandle.standardError.write(Data("failed to register \(fontPath)\n".utf8))
        exit(1)
    }
    if id != sharedFontID {
        FileHandle.standardError.write(
            Data("warning: font registered as \(id), producer assumes \(sharedFontID)\n".utf8)
        )
    }
    var attached = editor.attachDrawArena(id: arenaID)
    var lastAttempt = Date.distantPast
    while editor.isOpen {
        editor.pumpEvents(timeout: 1.0 / 120.0)
        if !attached, Date().timeIntervalSince(lastAttempt) > 0.5 {
            lastAttempt = Date()
            attached = editor.attachDrawArena(id: arenaID)
        }
        while editor.pollInputEvent() != nil {}
        editor.renderFrame()
    }
#endif
}

#if canImport(LavaIDL)
/// What the compositor's own window says. Recomputed every iteration and
/// compared, so the root repaints when the answer changes and not on every
/// frame some client happens to publish.
func compositorStatus() -> [String] {
    let surfaces = SurfaceRegistry.all
    guard !surfaces.isEmpty else {
        return [
            "LavaUI compositor — no clients",
            "",
            "run:  ArenaDemo produce <name>",
        ]
    }
    return ["LavaUI compositor — \(surfaces.count) surface(s)", ""]
        + surfaces.map { "#\($0.id)  \($0.title)  ·  arena \($0.arenaId)" }
}

/// Draws the root window from this process, through the ordinary in-process
/// `DrawList` path — the same renderer, fed from local memory instead of from
/// a client's arena.
func drawCompositorStatus(editor: Editor, list: DrawList, lines: [String]) {
    let size = editor.framebufferSize(window: .main)
    list.clear()
    list.rect(x: 0, y: 0, w: size.w, h: size.h,
              color: Color(r: 0.09, g: 0.09, b: 0.12))
    var y: Float = 20
    for (index, line) in lines.enumerated() {
        list.text(
            line, x: 20, y: y, w: size.w - 40, h: 22,
            color: index == 0
                ? Color(r: 0.95, g: 0.95, b: 0.98)
                : Color(r: 0.63, g: 0.67, b: 0.78)
        )
        y += 26
    }
    editor.submitDrawList(list)
}
#endif

// ─── App ─────────────────────────────────────────────────────────────────────

/// Producer-side engine state. File scope rather than borrowed into
/// `FrameWriter`: both are used for the life of the process, and handing a
/// struct a pointer to a local would outlive the local it points at.
nonisolated(unsafe) var arena = canvas.ipc.DrawArena()
nonisolated(unsafe) var font = canvas.Font()

#if canImport(LavaIDL)
/// The `Rpc` owns the transport — the shared-memory listener, its ring
/// buffers, the worker threads. Held at file scope because ARC releases a
/// local at its *last use*, not at end of scope, so binding it to `_` inside a
/// function tears the whole runtime down immediately: the listener stops, the
/// ring buffers are unlinked, and the next call through a proxy that outlived
/// it segfaults.
nonisolated(unsafe) var rpcRuntime: Rpc?
#endif

func runProducer() {
    guard font.load(std.string(fontPath), fontPixelSize).has_value() else {
        FileHandle.standardError.write(Data("failed to load \(fontPath)\n".utf8))
        exit(1)
    }

    // Deliberately tiny, so the growth path runs in the first few seconds
    // rather than only under a pathological UI. A real producer would start
    // at `kDefaultArenaCapacity`.
    var capacity = canvas.ipc.ArenaCapacity()
    capacity.commands = 8
    capacity.glyphs = 64
    capacity.meshVertices = 8
    capacity.spatialVertices = 8
    guard arena.create(std.string(arenaID), capacity) else {
        FileHandle.standardError.write(
            Data("failed to create arena '\(arenaID)' — is one already running?\n".utf8)
        )
        exit(1)
    }
    FileHandle.standardError.write(
        Data("arena '\(arenaID)' created (\(arena.mappedBytes() / 1024) KiB)\n".utf8)
    )

#if canImport(LavaIDL)
    // Order matters: the arena has to exist before `CreateSurface`, because
    // the renderer opens what the producer made. Registering the font first is
    // free either way and gets the id every glyph below is stamped with.
    var compositorOpt: Compositor?
    var inputOpt: InputChannel?
    var surfaceIDOpt: UInt32?
    do {
        let (compositor, rpc) = try connectToCompositor()
        rpcRuntime = rpc
        // Through the same `GPUResourceHost` a LavaUI client installs, rather
        // than calling the interface directly. There is one path from "I need
        // an id" to "the renderer gave me one", and this producer takes it too
        // — a second one that happened to work would be a second one to keep
        // working.
        let resources = CompositorResources(compositor)
        guard let fontID = resources.registerFont(path: fontPath, pixelSize: fontPixelSize)
        else { throw ControlPlaneError.timedOut }
        sharedFontID = fontID

        // Exercises the image half of the same interface. Opt-in because this
        // producer hand-writes its commands and has no image command to draw
        // one with — what is being checked is the round trip and the size that
        // comes back, which is what a client would lay out against.
        if let path = ProcessInfo.processInfo.environment["LAVA_DEMO_IMAGE"] {
            let cap = UInt32(ProcessInfo.processInfo.environment["LAVA_DEMO_IMAGE_MAX"] ?? "")
                ?? 0
            if let image = resources.registerImage(path: path, maxPixelSize: cap) {
                let line = "RegisterImage → texture \(image.textureId) "
                    + "\(Int(image.pixelWidth))×\(Int(image.pixelHeight))\n"
                FileHandle.standardError.write(Data(line.utf8))
            } else {
                FileHandle.standardError.write(
                    Data("RegisterImage(\(path)) got nothing back\n".utf8)
                )
            }
        }
        // Longer than the default: this one opens a window and builds a
        // swapchain, which on a cold device is not a microsecond-scale call
        // like the rest of this interface.
        let surfaceID: UInt32 = try blockingCall(timeout: 10) {
            try await compositor.createSurface(
                arenaId: arenaID, width: 720, height: 480, title: clientName
            )
        }
        // Only after `CreateSurface`: the id has to exist before it can be
        // subscribed to. Out of order, this throws `SurfaceNotFound` right
        // here — the servant's guard runs before it touches the stream, so
        // the failure comes back as a typed exception at the call instead of
        // as a stream that opens and then dies.
        //
        // Not `blockingCall`-wrapped — opening a stream is synchronous. What
        // comes back is a pair of endpoints, not an answer, so there is no
        // reply to wait for and nothing to strand.
        inputOpt = InputChannel(stream: try compositor.subscribeInput(surfaceId: surfaceID))
        compositorOpt = compositor
        surfaceIDOpt = surfaceID
        FileHandle.standardError.write(
            Data("control plane up — surface \(surfaceID), font id \(sharedFontID)\n".utf8)
        )
    } catch let error as ControlPlaneError {
        // Reaching the compositor at all is the only failure a running host
        // cannot explain, so it is the only one worth guessing about.
        FileHandle.standardError.write(
            Data("no compositor (\(error)) — is the host running?\n".utf8)
        )
        exit(1)
    } catch {
        // Everything else is a typed exception the renderer chose to send:
        // FontNotFound, ArenaNotFound. It knows what went wrong, so it says so.
        FileHandle.standardError.write(Data("refused by the compositor: \(error)\n".utf8))
        exit(1)
    }
    let compositor = compositorOpt
    let input = inputOpt
    let surfaceID = surfaceIDOpt ?? 0

    /// Hands the surface back on a clean exit. Not required for correctness —
    /// the input stream ending says the same thing — but a client that knows
    /// it is finished should say so rather than making the compositor infer
    /// it from a socket.
    func releaseSurface() {
        guard let compositor else { return }
        try? blockingCall { try await compositor.destroySurface(surfaceId: surfaceID) }
    }
#endif

    // What the renderer tells us about its window. The initial values are
    // only ever used without a control plane; with one, the first event to
    // arrive is a `Resize` carrying the real size.
    var viewW: Float = 720
    var viewH: Float = 480
    var pointerX: Float = -1
    var pointerY: Float = -1
    var clicks = 0
    var scrolls = 0
    /// The scrolling panel. Stable across frames because that is what
    /// the renderer keys its retained state on.
    let listNodeID: UInt32 = 1
    /// Row nodes are numbered from here, well clear of the panel's own
    /// id and of zero, which the renderer reads as "no node".
    let rowNodeBase: UInt32 = 1_000
    let cardNodeID: UInt32 = 2
    /// Which of two resting places the card should be in. Flipped by
    /// the space bar; the motion between them is not this process's
    /// business and never appears in any frame it writes.
    var cardOpen = true
    let badgeNodeID: UInt32 = 10
    /// How many chips have reported arriving since the last toggle. The
    /// renderer counts the frames; this only counts the arrivals.
    var chipsLanded = 0
    /// Which node the pointer is over, as reported by the renderer.
    /// Never computed here — see `.nodeHover`.
    var hoveredNode: UInt32 = 0
    var selectedRow = -1
    let rowCount = 5_000
    /// Where the renderer has scrolled the panel to, as reported back
    /// on the input stream. This process never sets it.
    var listScrollY: Float = 0

    let start = Date()
    var frame = 0
    while true {
#if canImport(LavaIDL)
        if let input {
            // The surface is gone — the user closed the window, or the
            // renderer did. Frames from here on would go into an arena
            // nobody is mapping.
            if input.isClosed { break }
            for event in input.drain() {
                // `InputEventKind` is LavaUI's, unchanged: the wire struct is
                // congruent with `canvas::InputEvent` precisely so that both
                // processes read the same enum rather than each keeping a
                // private copy that can drift.
                switch InputEventKind(rawValue: event.kind) ?? .none {
                case .resize:
                    viewW = event.x
                    viewH = event.y
                case .mouseMove:
                    pointerX = event.x
                    pointerY = event.y
                case .mouseDown:
                    clicks += 1
                    // Routed, not hit-tested. The last `.nodeHover` is the
                    // node this click is for — and it is right even for rows
                    // the renderer has scrolled somewhere else, which a
                    // coordinate test against the declared position would
                    // get wrong precisely when it mattered.
                    if hoveredNode >= rowNodeBase {
                        selectedRow = Int(hoveredNode - rowNodeBase)
                    }
                case .nodeHover:
                    hoveredNode = UInt32(max(0, event.button))
                case .scroll:
                    // Only the ones the renderer did *not* take. A wheel over
                    // the panel never gets here — that subtree is the
                    // renderer's to move — so this counter is the visible
                    // difference between the retained half and the immediate
                    // one.
                    scrolls += 1
                case .nodeScroll:
                    // Where the renderer put our node. We did not decide it
                    // and could not have — but knowing it is what lets the
                    // rows below be emitted for the window rather than for
                    // the whole list.
                    if event.button == Int32(listNodeID) { listScrollY = event.y }
                case .key:
                    // GLFW key codes: 256 is Escape, `x` is the action and is
                    // zero on release.
                    if event.button == 256, event.x != 0 {
                        releaseSurface()
                        return
                    }
                    // 32 is space. One flag flip is the entire animation as
                    // far as this process is concerned.
                    if event.button == 32, event.x == 1 {
                        cardOpen.toggle()
                        chipsLanded = 0
                    }
                case .nodeAnimationDone:
                    // Sequencing without a timer. This process has no idea
                    // how long the move took and does not need one — it is
                    // told when the thing it asked for happened.
                    let id = UInt32(max(0, event.button))
                    if id >= cardNodeID, id < cardNodeID + 3 { chipsLanded += 1 }
                default:
                    break
                }
            }
        }
#endif

        let t = Float(Date().timeIntervalSince(start))
        var writer = FrameWriter()
        guard writer.begin() else { break }

        writer.rect(x: 0, y: 0, w: viewW, h: viewH, color: 0xff2b2b33)

        // A bar chart whose bar count grows with time, so the command count
        // climbs past the initial capacity and forces the arena to grow
        // mid-frame — the case a ring buffer cannot serve, and the reason
        // this is a mapping. It is also laid out to the size the renderer
        // reported, which is the visible proof the reverse channel works:
        // before it existed, resizing the window left black margins because
        // this process had no way to hear about it.
        // ─── Producer-declared animation ─────────────────────────────────
        //
        // This process states where each chip should be and moves on. It does
        // not tween, does not schedule anything, and emits identical frames
        // while they are in flight — the two resting states are the only ones
        // it ever describes. Everything between them is the renderer's, which
        // is why it still arrives if this process is stopped mid-move.
        //
        // Three chips travelling 70, 150 and 230 pixels, all given the same
        // *duration*. That is the point of a duration: under a decay the
        // near one would visibly settle while the far one was still going,
        // and one gesture would read as three. Sharing a duration, they leave
        // together and land together.
        let chipTravel: [Float] = [70, 150, 230]
        for (index, travel) in chipTravel.enumerated() {
            let y = 214 + Float(index) * 38
            writer.beginNode(id: cardNodeID + UInt32(index), x: 40, y: y,
                             w: 300, h: 32, flags: 0)
            writer.animateNode(
                opacity: cardOpen ? 1.0 : 0.2,
                translateX: cardOpen ? 0 : travel,
                translateY: 0,
                duration: 0.5
            )
            writer.rect(x: 0, y: 0, w: 300, h: 32, color: 0xff3b3b4d)
            writer.rect(x: 0, y: 0, w: 5, h: 32, color: barColor(index))
            writer.text("chip \(index) — travels \(Int(travel))px", x: 16, y: 5)
            writer.endNode(contentW: 300, contentH: 32)
        }
        // Sequenced off the arrivals, not off a clock. The badge cannot show
        // up early because this process has no way to know the transition is
        // nearly done — only that it is, or is not, finished.
        let badgeIn = chipsLanded >= 3
        writer.beginNode(id: badgeNodeID, x: 40, y: 332, w: 260, h: 30, flags: 0)
        writer.animateNode(
            opacity: badgeIn ? 1.0 : 0.0,
            translateX: 0, translateY: badgeIn ? 0 : -14,
            duration: 0.22
        )
        writer.rect(x: 0, y: 0, w: 260, h: 30, color: 0xff2f4f3f)
        writer.text("all three landed", x: 12, y: 4, color: 0xffa7f3c0)
        writer.endNode(contentW: 260, contentH: 30)

        writer.text(cardOpen ? "space: chips home" : "space: chips away",
                    x: 40, y: 380, color: 0xff8ea0c8)
        writer.text("arrivals reported: \(chipsLanded)/3",
                    x: 40, y: 410, color: 0xff8ea0c8)
        writer.text(
            selectedRow < 0
                ? "no row selected — click one"
                : "row \(selectedRow) selected, routed by node id",
            x: 40, y: 440, color: 0xff8ea0c8)

        let chartWidth = max(120, viewW * 0.5 - 40)
        let baseline = viewH - 40
        let barPitch: Float = 28
        let barWidth: Float = 20
        let room = max(60, baseline - 490)
        let bars = min(3 + Int(t) % 22, max(1, Int((chartWidth - 40) / barPitch)))
        var hovered = -1
        for i in 0..<bars {
            let phase = t * 1.6 + Float(i) * 0.35
            let h = 30 + (room - 30) * (0.5 + 0.5 * sin(phase))
            let x = 40 + Float(i) * barPitch
            // Hit-tested here, in the process that knows what a bar is. The
            // renderer forwarded a coordinate and nothing more.
            let hit = pointerX >= x && pointerX < x + barWidth
                && pointerY >= baseline - h && pointerY < baseline
            if hit { hovered = i }
            writer.rect(x: x, y: baseline - h, w: barWidth, h: h,
                        color: hit ? 0xfff8fafc : barColor(i))
        }

        // ─── The retained half ───────────────────────────────────────────
        //
        // Everything above is immediate: republished every frame, owned by
        // nobody once written. This is a *node*, and the difference is that
        // the renderer keeps state against its id — where it has been
        // scrolled to — which survives this process republishing the list.
        //
        // So the wheel over this panel never reaches this process. The
        // renderer moves the subtree and repaints from the frame it already
        // has. Stop this process with SIGSTOP and the panel still scrolls;
        // the bars beside it, which need a new frame to move, freeze.
        let panelX = viewW * 0.52
        let panelY: Float = 250
        let panelW = max(80, viewW - panelX - 30)
        let panelH = max(80, viewH - panelY - 30)
        let rowPitch: Float = 34
        let contentH = Float(rowCount) * rowPitch

        // Virtualized, which is what the read-back is for. Five thousand rows
        // is 15,000 commands nobody would ever see; emitting the dozen that
        // are on screen needs `listScrollY`, and the only process that knows
        // it is the one doing the scrolling.
        //
        // Overscanned by three rows because this is a frame behind: the
        // offset arrived with the last batch of input and the renderer has
        // been easing onward since. Three rows is more than an ease covers in
        // a frame, so the edge is never blank.
        let overscan = 3
        let firstRow = max(0, Int(listScrollY / rowPitch) - overscan)
        let lastRow = min(rowCount - 1,
                          Int((listScrollY + panelH) / rowPitch) + overscan)

        writer.text("scroll this panel — the renderer moves it, not this process",
                    x: panelX - 8, y: panelY - 32, color: 0xff8ea0c8)
        writer.rect(x: panelX - 8, y: panelY - 8, w: panelW + 16, h: panelH + 16,
                    color: 0xff20202a)
        writer.beginNode(
            id: listNodeID, x: panelX, y: panelY, w: panelW, h: panelH,
            flags: SceneNodeFlags([.clip, .scrollY]).rawValue
        )
        for row in firstRow...max(firstRow, lastRow) {
            // Positioned in the node's own content space, not the window's:
            // the renderer adds the node's origin and subtracts wherever it
            // has scrolled to.
            let y = Float(row) * rowPitch
            // Each row is a node of its own, so it can light up under the
            // pointer without this process being told the pointer moved.
            // Nested inside the scrolling node, which means its hit rect
            // follows the scroll for free — the renderer records where a node
            // actually landed, not where it was declared.
            //
            // Offset from one so no id is zero, which the renderer reads as
            // "no node".
            writer.beginNode(id: rowNodeBase + UInt32(row), x: 0, y: y,
                             w: panelW, h: rowPitch - 4, flags: 0)
            writer.rect(x: 0, y: 0, w: panelW, h: rowPitch - 4,
                        color: row % 2 == 0 ? 0xff2f2f3b : 0xff343442)
            let picked = row == selectedRow
            writer.rect(x: 0, y: 0, w: picked ? 10 : 4, h: rowPitch - 4,
                        color: picked ? 0xffffffff : barColor(row))
            writer.text(picked ? "row \(row) — selected" : "row \(row) — click me",
                        x: 16, y: 6, color: picked ? 0xffffffff : 0xffd8d8e4)
            // Declared once. The renderer decides when they apply, and
            // repaints on its own when the answer changes.
            writer.endNode(contentW: panelW, contentH: rowPitch - 4,
                           hoverTint: 0x1cffffff, pressTint: 0x3cffffff)
        }
        // Both: how far this panel can *eventually* scroll, and how far it
        // can scroll with what is in the arena right now. Without the second
        // the renderer would scroll past the rows this frame drew and show
        // blank — which is exactly what happens when the producer is slow,
        // or stopped.
        writer.endNode(
            contentW: panelW, contentH: contentH,
            emittedTop: Float(firstRow) * rowPitch,
            emittedBottom: Float(lastRow + 1) * rowPitch
        )

        if pointerX >= 0 {
            writer.rect(x: pointerX - 0.5, y: 0, w: 1, h: viewH, color: 0x40ffffff)
            writer.rect(x: 0, y: pointerY - 0.5, w: viewW, h: 1, color: 0x40ffffff)
        }

        writer.text("draw list written by pid \(getpid()) — no GPU, no window",
                    x: 40, y: 60)
        writer.text("frame \(frame) · \(bars) bars · generation \(arena.generation())",
                    x: 40, y: 92)
        writer.text("surface \(Int(viewW))×\(Int(viewH)), as reported by the renderer",
                    x: 40, y: 124)
        writer.text(
            pointerLabel(x: pointerX, y: pointerY, hovered: hovered,
                         clicks: clicks, scrolls: scrolls),
            x: 40, y: 156)
        writer.text(
            "rows \(firstRow)–\(lastRow) of \(rowCount) · "
            + "panel held at y=\(Int(listScrollY))",
            x: 40, y: 188, color: 0xff8ea0c8)

        writer.commit()
#if canImport(LavaIDL)
        // Fire and forget. The arena's published sequence already says what is
        // current, so a dropped nudge costs a frame of latency and never a
        // frame of content — which is exactly what `[unreliable]` is for.
        if let compositor {
            // Not awaited: `[unreliable]` has no reply to wait for, and a
            // frame loop should not pay a scheduling round trip to say "go".
            Task.detached { await compositor.present(surfaceId: surfaceID) }
        }
#endif
        frame += 1

        if frame % 120 == 0 {
            let line = "frame \(frame): generation \(arena.generation()), "
                + "\(arena.mappedBytes() / 1024) KiB\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        Thread.sleep(forTimeInterval: 1.0 / 60.0)
    }
}

private func pointerLabel(
    x: Float, y: Float, hovered: Int, clicks: Int, scrolls: Int
) -> String {
    guard x >= 0 else { return "move the pointer over the window" }
    let bar = hovered >= 0 ? "bar \(hovered)" : "—"
    return "pointer \(Int(x)),\(Int(y)) · \(bar) · \(clicks) clicks · "
        + "\(scrolls) scrolls seen here"
}

private func barColor(_ i: Int) -> UInt32 {
    let palette: [UInt32] = [
        0xff7dd3fc, 0xffa78bfa, 0xfff9a8d4, 0xfffcd34d, 0xff86efac,
    ]
    return palette[i % palette.count]
}

/// Writes one frame into the arena, growing it when an append does not fit.
///
/// The growth check is per append rather than up front for the same reason
/// `DrawList` grows during emit: how many commands a frame needs is not known
/// until it has been emitted.
private struct FrameWriter {
    var frame = canvas.ipc.ArenaFrame()
    var commands = 0
    var glyphs = 0

    mutating func begin() -> Bool {
        frame = arena.beginFrame()
        return frame.valid
    }

    /// Asks for room for `moreCommands`/`moreGlyphs`, growing if needed.
    /// Returns false only when growth itself failed, in which case the caller
    /// silently drops what would not fit.
    private mutating func reserve(commands moreCommands: Int, glyphs moreGlyphs: Int) -> Bool {
        let needCommands = UInt32(commands + moreCommands)
        let needGlyphs = UInt32(glyphs + moreGlyphs)
        if needCommands <= frame.capacity.commands, needGlyphs <= frame.capacity.glyphs {
            return true
        }
        var atLeast = canvas.ipc.ArenaCapacity()
        atLeast.commands = needCommands
        atLeast.glyphs = needGlyphs
        var written = canvas.ipc.ArenaCapacity()
        written.commands = UInt32(commands)
        written.glyphs = UInt32(glyphs)
        return arena.growFrame(&frame, atLeast, written)
    }

    /// Opens a scene node. Children are positioned *local* to it — the
    /// renderer adds the node's own offset, plus whatever it has scrolled the
    /// node to, when it builds the vertices.
    mutating func beginNode(
        id: UInt32, x: Float, y: Float, w: Float, h: Float, flags: UInt32
    ) {
        guard reserve(commands: 1, glyphs: 0) else { return }
        var cmd = canvas.DrawCommand()
        cmd.kind = 16  // BeginNode
        cmd.x = x
        cmd.y = y
        cmd.w = w
        cmd.h = h
        cmd.color = flags
        cmd.param = id
        frame.commands[commands] = cmd
        commands += 1
    }

    /// `emittedTop`/`emittedBottom` say how much of `contentH` was actually
    /// drawn. Leaving them zero means "all of it".
    /// States the enclosing node's animation target. See `NodeAnimate`.
    mutating func animateNode(
        opacity: Float, translateX: Float, translateY: Float,
        timeConstant: Float = 0, duration: Float? = nil
    ) {
        guard reserve(commands: 1, glyphs: 0) else { return }
        var cmd = canvas.DrawCommand()
        cmd.kind = 18  // NodeAnimate
        cmd.x = translateX
        cmd.y = translateY
        cmd.w = opacity
        // opacity | translate, plus duration when one is given.
        cmd.color = duration == nil ? 0b011 : 0b111
        cmd.aux = duration ?? timeConstant
        frame.commands[commands] = cmd
        commands += 1
    }

    mutating func endNode(
        contentW: Float, contentH: Float,
        emittedTop: Float = 0, emittedBottom: Float = 0,
        hoverTint: UInt32 = 0, pressTint: UInt32 = 0
    ) {
        guard reserve(commands: 1, glyphs: 0) else { return }
        var cmd = canvas.DrawCommand()
        cmd.kind = 17  // EndNode
        cmd.x = contentW
        cmd.y = contentH
        cmd.w = emittedTop
        cmd.h = emittedBottom
        cmd.color = hoverTint
        cmd.param = pressTint
        frame.commands[commands] = cmd
        commands += 1
    }

    mutating func rect(x: Float, y: Float, w: Float, h: Float, color: UInt32) {
        guard reserve(commands: 1, glyphs: 0) else { return }
        var cmd = canvas.DrawCommand()
        cmd.kind = 0  // Rect
        cmd.x = x
        cmd.y = y
        cmd.w = w
        cmd.h = h
        cmd.color = color
        frame.commands[commands] = cmd
        commands += 1
    }

    /// Shapes and appends a run. The renderer never sees the string — only
    /// glyph ids and pen positions, which is what lets it rasterize into a
    /// shared atlas without knowing what any client is saying.
    mutating func text(_ string: String, x: Float, y: Float, color: UInt32 = 0xffe8e8ef) {
        let n = Int(font.prepareShape(std.string(string)))
        guard n > 0 else { return }
        var shaped = [canvas.PositionedGlyph](
            repeating: canvas.PositionedGlyph(), count: n
        )
        let written = shaped.withUnsafeMutableBufferPointer {
            Int(font.copyShapedGlyphs($0.baseAddress, Int32(n)))
        }
        guard written > 0 else { return }
        guard reserve(commands: 1, glyphs: written) else { return }

        let first = glyphs
        for i in 0..<written {
            var gi = canvas.GlyphInstance()
            gi.glyphId = shaped[i].glyphId
            gi.fontId = sharedFontID
            gi.x = x + shaped[i].x
            gi.y = y + shaped[i].y
            frame.glyphs[first + i] = gi
        }
        glyphs += written

        var cmd = canvas.DrawCommand()
        cmd.kind = 2  // Text
        cmd.param = UInt32(first)
        cmd.w = Float(written)
        cmd.color = color
        frame.commands[commands] = cmd
        commands += 1
    }

    mutating func commit() {
        var written = canvas.ipc.ArenaCapacity()
        written.commands = UInt32(commands)
        written.glyphs = UInt32(glyphs)
        arena.commitFrame(frame, written)
    }
}

switch mode {
case "host": runHost()
case "produce", "producer": runProducer()
#if canImport(LavaIDL)
case "lavaui": runLavaUIClient()
#endif
default:
    FileHandle.standardError.write(
        Data("usage: ArenaDemo [host|produce [name]|lavaui [name]]\n".utf8)
    )
    exit(2)
}
#else
print("ArenaDemo needs the CxxCanvas engine.")
#endif
