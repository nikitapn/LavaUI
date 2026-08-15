import CxxCanvas
import CYoga
import Foundation

// Phase 3 — immediate draw list. C++ owns `canvas::DrawCommand` layout.

public enum DrawKind: UInt32 {
    case rect = 0
    case roundedRect = 1
    case text = 2
    case circle = 3
    case line = 4
    case pushClip = 5
    case popClip = 6
    case image = 7
    /// Flush UI so far, blur the resolve under x,y,w,h (`aux` = radius px).
    case beginBackdropBlur = 8
    /// Closes a blur scope (bookkeeping; engine no-ops today).
    case endBackdropBlur = 9
    /// Draw everything up to the matching End into an offscreen target instead
    /// of the frame, blur it, and composite it back over x,y,w,h with its own
    /// alpha (`aux` = radius px).
    case beginContentBlur = 10
    case endContentBlur = 11
    /// Filled arbitrary polygon. `param`/`w` index into `meshVertices`
    /// (first index, count); `aux` 0 fans around vertex 0, 1 triangulates
    /// alternating inner/outer pairs as a ring strip.
    case mesh = 12
    /// Connected 1px line strip. `param`/`w` index into `meshVertices`.
    case polyline = 13
    case spatialTriangles = 14
    /// Rounded rect filled with a two-stop linear ramp. `aux` = radius,
    /// `param` = index into the frame's gradients, `color` = the start colour
    /// so a consumer that ignores gradients still paints something sane.
    case linearGradientRect = 21
    /// Opens a scene node: `param` = id, x/y = local offset, w/h = viewport,
    /// `color` = `SceneNodeFlags`. See `draw_command.hpp` — the renderer owns
    /// state against the id, which is what a node has and a command does not.
    case beginNode = 16
    /// Closes the innermost node; x/y carry the content extent.
    case endNode = 17
    /// Declares what the enclosing node should animate toward. See
    /// `NodeAnimate` in `draw_command.hpp`.
    case nodeAnimate = 18
    /// Retargets the enclosing scroll node once per request serial.
    case nodeScrollTo = 20
    case spatialBegin = 15
    /// Declares `x,y,w,h` of this frame fully opaque. Draws nothing; lets a
    /// compositor stop blending the surface and skip what is behind it.
    /// See `OpaqueBounds` in `draw_command.hpp`.
    case opaqueBounds = 22
}

/// Bits in a `beginNode` command's `color` field. Mirrors
/// `canvas::SceneNodeFlags`.
public struct SceneNodeFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Clip children to the node's viewport, moving with the node.
    public static let clip = SceneNodeFlags(rawValue: 1 << 0)
    /// The renderer owns a vertical scroll offset for this node — wheel
    /// events inside it move the subtree without the producer hearing about
    /// it, or being woken to redraw.
    public static let scrollY = SceneNodeFlags(rawValue: 1 << 1)
    public static let scrollX = SceneNodeFlags(rawValue: 1 << 2)
    public static let hitTest = SceneNodeFlags(rawValue: 1 << 3)
    /// Commands inside the node use LavaUI's window-space coordinates. The
    /// renderer applies only retained transforms, not the node origin again.
    public static let absoluteCoordinates = SceneNodeFlags(rawValue: 1 << 4)
    /// This node handles the wheel itself, so the renderer must not scroll an
    /// enclosing container on its behalf. See `ScrollRouter`.
    public static let wheel = SceneNodeFlags(rawValue: 1 << 5)
}

/// Which properties a `animateNode` call is stating. Mirrors
/// `canvas::SceneAnimationFlags`.
public struct SceneAnimationFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let opacity = SceneAnimationFlags(rawValue: 1 << 0)
    public static let translate = SceneAnimationFlags(rawValue: 1 << 1)
    /// Read the time value as a duration rather than a decay constant — see
    /// `kSceneAnimDuration` in `draw_command.hpp`.
    public static let duration = SceneAnimationFlags(rawValue: 1 << 2)
}

/// Reused arena: draw commands plus the shaped glyphs they reference.
/// Shaping itself is cached per line on `UIFont`, so re-emission is cheap.
public final class DrawList {
    unowned let editor: Editor
    /// Which window's arena this list writes into. One list per window: the
    /// storage pointers below are that window's, and a frame is committed to
    /// the window it was built for.
    let window: WindowID
    private var commandStorage: UnsafeMutablePointer<canvas.DrawCommand>
    private var commandCapacity: Int
    /// Public so a harness outside LavaUI (`LavaBench`) can assert on the
    /// *shape* of a frame — command/glyph counts are exact where timings are
    /// noisy. See `PerfCounters`.
    public private(set) var commandCount = 0

    /// Shaped glyphs in absolute window pixels; `Text` commands index this.
    /// Replaces the old string blob — the renderer no longer shapes anything,
    /// so strings never cross the boundary.
    private var glyphStorage: UnsafeMutablePointer<canvas.GlyphInstance>
    private var glyphCapacity: Int
    public private(set) var glyphCount = 0

    /// Polygon vertices in absolute window pixels; `Mesh` commands index this
    /// the same way `Text` indexes `glyphs`.
    private var meshVertexStorage: UnsafeMutablePointer<canvas.MeshVertex>
    private var meshVertexCapacity: Int
    public private(set) var meshVertexCount = 0
    private var spatialVertexStorage: UnsafeMutablePointer<canvas.SpatialVertex>
    private var spatialVertexCapacity: Int
    public private(set) var spatialVertexCount = 0
    private var gradientStorage: UnsafeMutablePointer<canvas.GradientDesc>
    private var gradientCapacity: Int
    public private(set) var gradientCount = 0

    /// Overlays found during the current walk, emitted once it finishes.
    private var pendingOverlays: [PendingOverlay] = []

    /// Fade applied to everything appended, for transitions. A multiplier
    /// rather than a value so nested transitions compose.
    private var alphaMultiplier: Float = 1

    /// True inside any blur scope, of either kind. See `withBlurScope`.
    private var insideBlurScope = false

    /// Axis-aligned cull region in window pixels. Starts as the framebuffer;
    /// each `ScrollView` intersects it with its scissor so off-screen scroll
    /// content is skipped before any draw commands are issued.
    private var cullStack: [CullRect] = []

    /// What the renderer will add to the subtree currently being emitted,
    /// accumulated from the scroll containers around it.
    ///
    /// Ordinary commands never need this — the renderer applies it as their
    /// vertices are built, which is the entire point of a retained node. An
    /// *overlay* does. It is recorded during the walk but emitted after it,
    /// outside every node, so nothing is going to move it: its anchor has to
    /// be stated in the coordinates it will actually be drawn in, or a popup
    /// opens where its button would have been had the page never scrolled.
    ///
    /// Scroll only. A producer-declared translation moves a node too, but
    /// nothing in LavaUI declares one around an overlay presenter yet, and
    /// guessing at the arithmetic for a case with no caller would be a second
    /// thing to keep true.
    private var retainedShift: (x: Float, y: Float) = (0, 0)

    /// Where this frame lives and who gets it. The engine's own buffers
    /// unless the editor was told otherwise — see `Editor.frames`.
    private let sink: any FrameSink

    /// The first frame's ask. Only a starting point: `grow` doubles from here
    /// as a tree turns out to be bigger than the last one was.
    private static let initialCapacity = FrameCapacity(
        commands: 256, glyphs: 2048, meshVertices: 256, spatialVertices: 256,
        gradients: 16
    )

    public init(editor: Editor, window: WindowID = .main) {
        self.editor = editor
        self.window = window
        self.sink = editor.frames(for: window)
        let buffers = sink.beginFrame(minimum: Self.initialCapacity)
        commandStorage = buffers?.commands ?? Self.nowhere()
        glyphStorage = buffers?.glyphs ?? Self.nowhere()
        meshVertexStorage = buffers?.meshVertices ?? Self.nowhere()
        spatialVertexStorage = buffers?.spatialVertices ?? Self.nowhere()
        gradientStorage = buffers?.gradients ?? Self.nowhere()
        commandCapacity = buffers?.capacity.commands ?? 0
        glyphCapacity = buffers?.capacity.glyphs ?? 0
        meshVertexCapacity = buffers?.capacity.meshVertices ?? 0
        spatialVertexCapacity = buffers?.capacity.spatialVertices ?? 0
        gradientCapacity = buffers?.capacity.gradients ?? 0
    }

    /// A one-element buffer for a frame with no storage, so the pointers are
    /// never null and every append is refused by the capacity check instead.
    /// Reached only when a sink declines to hand out a slot.
    private static func nowhere<T>() -> UnsafeMutablePointer<T> {
        UnsafeMutablePointer<T>.allocate(capacity: 1)
    }

    /// Starts a frame: resets the counts and claims storage for it.
    ///
    /// Claiming here rather than once at init is what a shared arena needs —
    /// it is triple buffered, so the slot a frame is written into is chosen
    /// per frame and the pointers move with it. The in-process sink hands back
    /// the same buffers every time, so nothing changes for a windowed app.
    public func clear() {
        commandCount = 0
        glyphCount = 0
        meshVertexCount = 0
        spatialVertexCount = 0
        gradientCount = 0
        cullStack.removeAll(keepingCapacity: true)
        adopt(sink.beginFrame(minimum: Self.initialCapacity))
    }

    /// One emitted command, for tests asserting on the shape of a frame.
    ///
    /// Read-back rather than a mirror kept alongside: what a test wants to know
    /// is what actually reached the arena, and a second record of it could
    /// agree with the test while the arena disagreed with both.
    ///
    /// Repackaged into a plain tuple rather than handed over as the C++ struct
    /// it is stored as: a member whose signature names a C++ type is not
    /// visible to a module that has not itself enabled interop, so returning
    /// one would make this accessor unusable from exactly the place it exists
    /// for.
    func emitted(at index: Int)
        -> (
            kind: DrawKind?, x: Float, y: Float, w: Float, h: Float,
            aux: Float, param: UInt32, color: UInt32
        )?
    {
        guard index >= 0, index < commandCount else { return nil }
        let cmd = commandStorage[index]
        return (
            DrawKind(rawValue: cmd.kind), cmd.x, cmd.y, cmd.w, cmd.h, cmd.aux,
            cmd.param, cmd.color
        )
    }

    /// Hands the frame to its sink. Returns whether anything was published —
    /// false when no storage was claimed, which is a frame skipped rather
    /// than a failure.
    @discardableResult
    public func publish() -> Bool {
        guard commandCapacity > 0 else { return false }
        sink.commit(written)
        return true
    }

    private var written: FrameCapacity {
        FrameCapacity(
            commands: commandCount, glyphs: glyphCount,
            meshVertices: meshVertexCount, spatialVertices: spatialVertexCount,
            gradients: gradientCount
        )
    }

    /// Says once that a frame is being truncated.
    ///
    /// Every append below refuses rather than overruns when its sink would not
    /// grow, which is right — but silent. Content that is simply missing from
    /// a frame is one of the most expensive things to debug: no crash, no
    /// error, and it usually looks like a layout or culling bug rather than a
    /// capacity one. So it says so.
    private static func noteTruncated(_ what: String, at count: Int) {
        guard !truncationWarned else { return }
        truncationWarned = true
        let line = "DrawList: out of room for \(what) at \(count); this frame "
            + "is truncated and content will be missing.\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    nonisolated(unsafe) private static var truncationWarned = false

    private func adopt(_ buffers: FrameBuffers?) {
        guard let buffers else {
            // Nothing to write into. Zero capacity refuses every append, so
            // the frame comes out empty rather than landing somewhere else.
            commandCapacity = 0
            glyphCapacity = 0
            meshVertexCapacity = 0
            spatialVertexCapacity = 0
            gradientCapacity = 0
            return
        }
        commandStorage = buffers.commands
        glyphStorage = buffers.glyphs
        meshVertexStorage = buffers.meshVertices
        spatialVertexStorage = buffers.spatialVertices
        gradientStorage = buffers.gradients
        commandCapacity = buffers.capacity.commands
        glyphCapacity = buffers.capacity.glyphs
        meshVertexCapacity = buffers.capacity.meshVertices
        spatialVertexCapacity = buffers.capacity.spatialVertices
        gradientCapacity = buffers.capacity.gradients
    }

    private func grow(
        commands: Int = 0, glyphs: Int = 0, meshVertices: Int = 0,
        spatialVertices: Int = 0, gradients: Int = 0
    ) {
        let wanted = FrameCapacity(
            commands: commands > commandCapacity
                ? max(commands, max(256, commandCapacity * 2)) : commandCapacity,
            glyphs: glyphs > glyphCapacity
                ? max(glyphs, max(2048, glyphCapacity * 2)) : glyphCapacity,
            meshVertices: meshVertices > meshVertexCapacity
                ? max(meshVertices, max(256, meshVertexCapacity * 2)) : meshVertexCapacity,
            spatialVertices: spatialVertices > spatialVertexCapacity
                ? max(spatialVertices, max(256, spatialVertexCapacity * 2))
                : spatialVertexCapacity,
            gradients: gradients > gradientCapacity
                ? max(gradients, max(16, gradientCapacity * 2)) : gradientCapacity
        )
        // A sink that cannot grow leaves the buffers it already handed out
        // valid, so the frame finishes smaller rather than being abandoned
        // partway through emit — which it could not be anyway, since the tree
        // walk is already halfway down.
        guard let buffers = sink.grow(to: wanted, written: written) else { return }
        adopt(buffers)
    }

    private func appendCommand(_ command: canvas.DrawCommand) {
        if commandCount == commandCapacity { grow(commands: commandCount + 1) }
        guard commandCount < commandCapacity else {
            Self.noteTruncated("commands", at: commandCount)
            return
        }
        commandStorage[commandCount] = command
        commandCount += 1
    }

    private func appendGlyph(_ glyph: canvas.GlyphInstance) {
        if glyphCount == glyphCapacity { grow(glyphs: glyphCount + 1) }
        guard glyphCount < glyphCapacity else {
            Self.noteTruncated("glyphs", at: glyphCount)
            return
        }
        glyphStorage[glyphCount] = glyph
        glyphCount += 1
    }

    private func appendMeshVertex(_ vertex: canvas.MeshVertex) {
        if meshVertexCount == meshVertexCapacity {
            grow(meshVertices: meshVertexCount + 1)
        }
        guard meshVertexCount < meshVertexCapacity else {
            Self.noteTruncated("mesh vertices", at: meshVertexCount)
            return
        }
        meshVertexStorage[meshVertexCount] = vertex
        meshVertexCount += 1
    }

    private func appendSpatialVertex(_ vertex: canvas.SpatialVertex) {
        if spatialVertexCount == spatialVertexCapacity {
            grow(spatialVertices: spatialVertexCount + 1)
        }
        guard spatialVertexCount < spatialVertexCapacity else {
            Self.noteTruncated("spatial vertices", at: spatialVertexCount)
            return
        }
        spatialVertexStorage[spatialVertexCount] = vertex
        spatialVertexCount += 1
    }

    /// Records one gradient and returns its index, or nil if there was no room.
    ///
    /// Returning the index rather than taking one is what keeps the two halves
    /// in step: the command that names it is written immediately afterwards,
    /// with whatever this actually allocated.
    private func appendGradient(_ desc: canvas.GradientDesc) -> UInt32? {
        if gradientCount == gradientCapacity {
            grow(gradients: gradientCount + 1)
        }
        guard gradientCount < gradientCapacity else {
            Self.noteTruncated("gradients", at: gradientCount)
            return nil
        }
        gradientStorage[gradientCount] = desc
        let index = UInt32(gradientCount)
        gradientCount += 1
        return index
    }

    func spatialTriangles(_ vertices: [SpatialProjectedVertex], texture: UIImage?) {
        guard vertices.count >= 3, vertices.count.isMultiple(of: 3) else { return }
        if let texture { ImageStore.touch(texture) }
        let first = spatialVertexCount
        for point in vertices {
            var vertex = canvas.SpatialVertex()
            vertex.x = point.x
            vertex.y = point.y
            vertex.z = point.depth
            vertex.u = point.u
            vertex.v = point.v
            vertex.color = point.color.rgba8
            vertex.textured = point.sampleMode
            appendSpatialVertex(vertex)
        }
        append(
            kind: .spatialTriangles, x: Float(texture?.textureId ?? 0), y: 0,
            w: Float(vertices.count), h: 0,
            color: Color(r: 1, g: 1, b: 1), param: UInt32(first)
        )
    }

    func beginSpatialScene(_ frame: CanvasFrame) {
        append(
            kind: .spatialBegin, x: frame.x, y: frame.y, w: frame.w, h: frame.h,
            color: Color(r: 1, g: 1, b: 1)
        )
    }

    /// Inclusive-exclusive AABB (x0 ≤ x < x1).
    private struct CullRect {
        var x0: Float
        var y0: Float
        var x1: Float
        var y1: Float

        static let empty = CullRect(x0: 0, y0: 0, x1: 0, y1: 0)

        var isEmpty: Bool { x1 <= x0 || y1 <= y0 }

        func intersects(x: Float, y: Float, w: Float, h: Float) -> Bool {
            // One-pixel pad so subpixel/scissor edges do not pop.
            let pad: Float = 1
            return x < x1 + pad && x + w > x0 - pad
                && y < y1 + pad && y + h > y0 - pad
        }

        func intersection(_ o: CullRect) -> CullRect {
            CullRect(
                x0: max(x0, o.x0), y0: max(y0, o.y0),
                x1: min(x1, o.x1), y1: min(y1, o.y1)
            )
        }
    }

    private var cull: CullRect {
        cullStack.last ?? CullRect(x0: 0, y0: 0, x1: 1e9, y1: 1e9)
    }

    private func append(
        kind: DrawKind,
        x: Float, y: Float, w: Float, h: Float,
        color: Color,
        param: UInt32 = 0,
        aux: Float = 0
    ) {
        var cmd = canvas.DrawCommand()
        cmd.kind = kind.rawValue
        cmd.x = x
        cmd.y = y
        cmd.w = w
        cmd.h = h
        // The single choke point every primitive goes through, which is why
        // the fade lives here rather than in each of them.
        if alphaMultiplier < 1 {
            var faded = color
            faded.a *= alphaMultiplier
            cmd.color = faded.rgba8
        } else {
            cmd.color = color.rgba8
        }
        cmd.param = param
        cmd.aux = aux
        appendCommand(cmd)
    }

    public func rect(x: Float, y: Float, w: Float, h: Float, color: Color) {
        append(kind: .rect, x: x, y: y, w: w, h: h, color: color)
    }

    /// Promises that `x,y,w,h` of this frame is fully opaque, so a compositor
    /// showing it can skip blending there — and skip drawing whatever is
    /// behind it entirely.
    ///
    /// Only worth saying for a compositor surface; a windowed app is pasted
    /// onto a swapchain and nobody asks. Emit before the tree, at the top
    /// level: the renderer ignores a claim made inside a scene node or a faded
    /// subtree, because those are about pixels the frame may not own.
    ///
    /// Claiming too little costs a blend. Claiming too much punches a hole
    /// through to the desktop, so anything uncertain — a translucent wash, a
    /// backdrop blur, a rounded corner the client drew itself — is a reason
    /// not to call this. The window's *own* rounding needs no allowance; the
    /// renderer insets for that, since it is the one that cuts the corners.
    public func opaqueBounds(x: Float, y: Float, w: Float, h: Float) {
        append(kind: .opaqueBounds, x: x, y: y, w: w, h: h, color: .clear)
    }

    public func roundedRect(
        x: Float, y: Float, w: Float, h: Float, color: Color, radius: Float = 4
    ) {
        append(kind: .roundedRect, x: x, y: y, w: w, h: h, color: color, aux: radius)
    }

    /// A rect filled with a two-stop linear ramp.
    ///
    /// `angle` is in radians from +x towards +y, so 0 runs left to right and
    /// `.pi / 2` runs top to bottom. The ramp spans the rect exactly whatever
    /// the angle and whatever the aspect ratio, and both stops carry their own
    /// alpha — a fade to transparent is `to:` with alpha 0, not a separate
    /// mechanism.
    ///
    /// Falls back to a flat `from` fill if the frame has no room left for
    /// another gradient, which is the same shape as every other truncation
    /// here: draw less than was asked for rather than nothing.
    public func linearGradientRect(
        x: Float, y: Float, w: Float, h: Float,
        from: Color, to: Color, angle: Float = .pi / 2, radius: Float = 0
    ) {
        var desc = canvas.GradientDesc()
        desc.color0 = from.rgba8
        desc.color1 = to.rgba8
        desc.angle = angle
        desc.flags = 0
        guard let index = appendGradient(desc) else {
            append(kind: .roundedRect, x: x, y: y, w: w, h: h, color: from,
                   aux: radius)
            return
        }
        append(kind: .linearGradientRect, x: x, y: y, w: w, h: h, color: from,
               param: index, aux: radius)
    }

    /// Shapes `string` (cached on the font) and appends its glyphs at
    /// absolute positions. `y` is the line box top; the pen sits at the
    /// baseline, i.e. `y + ascent`.
    public func text(
        _ string: String, x: Float, y: Float, w: Float, h: Float,
        color: Color, font: UIFont? = nil
    ) {
        guard let font = font ?? FontStore.default, !string.isEmpty else { return }
        let run = font.shape(string)
        guard !run.isEmpty else { return }

        let first = UInt32(glyphCount)
        let penX = x + 4  // matches the inset the old renderText path used
        let penY = y + font.ascent
        for g in run {
            var inst = canvas.GlyphInstance()
            inst.glyphId = g.glyphId
            // Per glyph, not per run: a fallback substitution puts glyphs from
            // another face in this same run, and ids are face-relative.
            inst.fontId = g.fontId
            inst.x = penX + g.x
            inst.y = penY + g.y
            appendGlyph(inst)
        }
        // `w` carries the glyph count for Text (see draw_command.hpp).
        append(
            kind: .text, x: x, y: y, w: Float(run.count), h: h,
            color: color, param: first
        )
    }

    public func circle(cx: Float, cy: Float, radius: Float, color: Color) {
        append(kind: .circle, x: cx, y: cy, w: 0, h: 0, color: color, aux: radius)
    }

    /// Stroke from (x1,y1) to (x2,y2). `width` is in pixels (capsule).
    public func line(
        x1: Float, y1: Float, x2: Float, y2: Float, color: Color, width: Float = 1.5
    ) {
        append(kind: .line, x: x1, y: y1, w: x2, h: y2, color: color, aux: max(0.5, width))
    }

    /// Draws connected points with one non-indexed `LINE_STRIP` GPU draw.
    ///
    /// This is intentionally 1px: portable Vulkan does not guarantee wide
    /// native lines. A future thick-polyline API should expand joins/caps into
    /// triangles rather than depend on the optional `wideLines` device feature.
    public func polyline(_ points: [(x: Float, y: Float)], color: Color) {
        guard points.count >= 2 else { return }
        let first = UInt32(meshVertexCount)
        if meshVertexCount + points.count > meshVertexCapacity {
            grow(meshVertices: meshVertexCount + points.count)
        }
        for point in points {
            var vertex = canvas.MeshVertex()
            vertex.x = point.x
            vertex.y = point.y
            appendMeshVertex(vertex)
        }
        append(
            kind: .polyline, x: 0, y: 0, w: Float(points.count), h: 0,
            color: color, param: first
        )
    }

    /// Fills a custom region fanned from its first point. Correct for any
    /// convex polygon, or any shape star-shaped from `points[0]` (able to
    /// see its whole boundary from there) — a wedge fanned from its centre,
    /// for instance. Concave shapes that are *not* star-shaped from the
    /// first point will self-intersect; that triangulation isn't supported.
    public func polygon(_ points: [(x: Float, y: Float)], color: Color) {
        guard points.count >= 3 else { return }
        emitMesh(points, color: color, isRing: false)
    }

    /// Fills a ring segment (annulus sector) between two arcs of equal point
    /// count — the shape a donut-chart wedge needs, where a hole in the
    /// middle means no single point can fan to the whole boundary.
    public func ring(
        inner: [(x: Float, y: Float)], outer: [(x: Float, y: Float)], color: Color
    ) {
        guard inner.count == outer.count, inner.count >= 2 else { return }
        var points: [(x: Float, y: Float)] = []
        points.reserveCapacity(inner.count * 2)
        for i in 0..<inner.count {
            points.append(inner[i])
            points.append(outer[i])
        }
        emitMesh(points, color: color, isRing: true)
    }

    /// Filled pie or donut wedge. `innerRadius <= 0` draws a solid slice
    /// (fanned from the centre); `innerRadius > 0` draws a ring segment.
    /// `segments` defaults to a density that keeps the arc looking smooth
    /// without over-tessellating short spans.
    public func pieSlice(
        cx: Float, cy: Float,
        innerRadius: Float, outerRadius: Float,
        startAngle: Float, endAngle: Float,
        color: Color, segments: Int? = nil
    ) {
        let span = abs(endAngle - startAngle)
        guard span > 0.0001, outerRadius > 0 else { return }
        let n = segments ?? max(3, min(96, Int(span / 0.026)))
        if innerRadius <= 0 {
            var points: [(x: Float, y: Float)] = [(cx, cy)]
            points.reserveCapacity(n + 2)
            for i in 0...n {
                let a = startAngle + (endAngle - startAngle) * (Float(i) / Float(n))
                points.append((cx + cos(a) * outerRadius, cy + sin(a) * outerRadius))
            }
            polygon(points, color: color)
        } else {
            var inner: [(x: Float, y: Float)] = []
            var outer: [(x: Float, y: Float)] = []
            inner.reserveCapacity(n + 1)
            outer.reserveCapacity(n + 1)
            for i in 0...n {
                let a = startAngle + (endAngle - startAngle) * (Float(i) / Float(n))
                let c = cos(a)
                let s = sin(a)
                inner.append((cx + c * innerRadius, cy + s * innerRadius))
                outer.append((cx + c * outerRadius, cy + s * outerRadius))
            }
            ring(inner: inner, outer: outer, color: color)
        }
    }

    private func emitMesh(_ points: [(x: Float, y: Float)], color: Color, isRing: Bool) {
        let first = UInt32(meshVertexCount)
        if meshVertexCount + points.count > meshVertexCapacity {
            grow(meshVertices: meshVertexCount + points.count)
        }
        for p in points {
            var v = canvas.MeshVertex()
            v.x = p.x
            v.y = p.y
            appendMeshVertex(v)
        }
        append(
            kind: .mesh, x: 0, y: 0, w: Float(points.count), h: 0,
            color: color, param: first, aux: isRing ? 1 : 0
        )
    }

    /// Opens a scene node — a subtree the renderer can move on its own.
    ///
    /// `id` is yours to assign and must be stable across frames: it is what
    /// the renderer keys its retained state on, so an id that changes between
    /// frames scrolls back to the top on every one.
    /// Not routed through `append`, unlike every primitive: `color` here is a
    /// flags bitfield, and `append` exists to put a *colour* through the
    /// opacity multiplier. Fading a node would turn `scrollY` into `clip`.
    /// Opens a node for a view, taking its scene id from its `NodeID`.
    ///
    /// The overload views should use: reconciliation already keeps `NodeID`
    /// stable across frames, and `SceneNodeIdentity` is what makes the number
    /// the renderer sees stable *and* safe to hand on when the node is gone.
    public func beginNode(
        _ node: NodeID, x: Float, y: Float, w: Float, h: Float,
        flags: SceneNodeFlags = []
    ) {
        beginNode(
            id: SceneNodeIdentity.id(for: node),
            x: x, y: y, w: w, h: h, flags: flags
        )
    }

    public func beginNode(
        id: UInt32, x: Float, y: Float, w: Float, h: Float,
        flags: SceneNodeFlags = []
    ) {
        var cmd = canvas.DrawCommand()
        cmd.kind = DrawKind.beginNode.rawValue
        cmd.x = x
        cmd.y = y
        cmd.w = w
        cmd.h = h
        cmd.color = flags.rawValue
        cmd.param = id
        appendCommand(cmd)
    }

    /// Closes the innermost node. `contentW`/`contentH` are how big its
    /// children turned out to be, which is what bounds a scroll.
    ///
    /// `emittedTop`/`emittedBottom` are the vertical span actually drawn, for
    /// a virtualized node that declares more content than it emits. Left at
    /// zero they mean "all of it", which is the truth for anything that draws
    /// its whole content.
    /// `hoverTint`/`pressTint` are drawn over the node while the pointer is
    /// inside it, and while it is additionally being pressed. The renderer
    /// applies them without asking, which is the point: hover is the most
    /// frequent state change in an interface and recomputing it here would
    /// cost a round trip per mouse move to reach an answer the renderer
    /// already had.
    public func endNode(
        contentW: Float, contentH: Float,
        emittedTop: Float = 0, emittedBottom: Float = 0,
        hoverTint: Color? = nil, pressTint: Color? = nil,
        cornerRadius: Float = 0
    ) {
        var cmd = canvas.DrawCommand()
        cmd.kind = DrawKind.endNode.rawValue
        cmd.x = contentW
        cmd.y = contentH
        cmd.w = emittedTop
        cmd.h = emittedBottom
        cmd.color = hoverTint?.rgba8 ?? 0
        cmd.param = pressTint?.rgba8 ?? 0
        // Renderer hover/press tints honour this so a rounded row does
        // not grow a square highlight. See `EndNode.aux`.
        cmd.aux = max(0, cornerRadius)
        appendCommand(cmd)
    }

    /// States where the enclosing node should end up. The renderer takes it
    /// there — at the display rate, without this process being scheduled
    /// again, and without stopping if this process gets busy.
    ///
    /// A property left `nil` is not stated, and keeps whatever target it had.
    /// The first frame a node states one it snaps rather than eases: a node
    /// that has just appeared has nothing to have moved from. To animate an
    /// entrance, state the start on one frame and the end on the next.
    /// Pass `duration` instead of `timeConstant` when several nodes have to
    /// arrive together: a decay from a longer distance takes visibly longer
    /// to settle, so a group easing with one time constant lands raggedly,
    /// while a group sharing a duration lands on one frame.
    public func animateNode(
        opacity: Float? = nil,
        translateX: Float? = nil, translateY: Float? = nil,
        timeConstant: Float = 0, duration: Float? = nil
    ) {
        var flags: SceneAnimationFlags = []
        if opacity != nil { flags.insert(.opacity) }
        if translateX != nil || translateY != nil { flags.insert(.translate) }
        if duration != nil { flags.insert(.duration) }
        guard !flags.isEmpty else { return }

        var cmd = canvas.DrawCommand()
        cmd.kind = DrawKind.nodeAnimate.rawValue
        cmd.x = translateX ?? 0
        cmd.y = translateY ?? 0
        cmd.w = opacity ?? 1
        cmd.color = flags.rawValue
        cmd.aux = duration ?? timeConstant
        appendCommand(cmd)
    }

    /// Asks the enclosing retained node to scroll toward a position. The
    /// renderer applies each serial once, so later wheel input is not undone
    /// merely because the same draw list is published again.
    func scrollNode(to offset: Float, serial: UInt32) {
        guard serial != 0 else { return }
        var cmd = canvas.DrawCommand()
        cmd.kind = DrawKind.nodeScrollTo.rawValue
        cmd.y = max(0, offset)
        cmd.param = serial
        appendCommand(cmd)
    }

    public func pushClip(x: Float, y: Float, w: Float, h: Float) {
        append(kind: .pushClip, x: x, y: y, w: w, h: h, color: .primary)
    }

    public func popClip() {
        append(kind: .popClip, x: 0, y: 0, w: 0, h: 0, color: .primary)
    }

    /// Textured quad. `param` = engine texture id; `color` = RGBA tint.
    public func image(
        textureId: UInt32,
        x: Float, y: Float, w: Float, h: Float,
        tint: Color = Color(r: 1, g: 1, b: 1)
    ) {
        guard w > 0, h > 0, textureId > 0 else { return }
        append(
            kind: .image, x: x, y: y, w: w, h: h,
            color: tint, param: textureId
        )
    }

    /// Barrier: engine flushes UI drawn so far, blurs under this rect, composites.
    /// `color` is unused by the engine (tint the glass with a following fill).
    ///
    /// `cornerRadius` is the radius of the surface that will be drawn over the
    /// frost. The composite is the one piece of a rounded glass panel the
    /// panel's own fill cannot hide — it is underneath it — so a square one
    /// shows as four bright tabs around the shape.
    public func beginBackdropBlur(
        x: Float, y: Float, w: Float, h: Float, radius: Float,
        cornerRadius: Float = 0
    ) {
        guard w > 0, h > 0, radius > 0 else { return }
        append(
            kind: .beginBackdropBlur, x: x, y: y, w: w, h: h,
            color: Color(r: 1, g: 1, b: 1),
            param: UInt32(max(0, cornerRadius.rounded())), aux: radius
        )
    }

    public func endBackdropBlur() {
        append(
            kind: .endBackdropBlur, x: 0, y: 0, w: 0, h: 0,
            color: Color(r: 1, g: 1, b: 1)
        )
    }

    /// Barrier: engine draws everything until `endContentBlur` into an offscreen
    /// target, blurs it, and composites it back over this rect.
    public func beginContentBlur(
        x: Float, y: Float, w: Float, h: Float, radius: Float
    ) {
        guard w > 0, h > 0, radius > 0 else { return }
        append(
            kind: .beginContentBlur, x: x, y: y, w: w, h: h,
            color: Color(r: 1, g: 1, b: 1), aux: radius
        )
    }

    public func endContentBlur() {
        append(
            kind: .endContentBlur, x: 0, y: 0, w: 0, h: 0,
            color: Color(r: 1, g: 1, b: 1)
        )
    }

    /// One offscreen Gaussian pass for a Scene3D effect such as a projected
    /// shadow mask or softened planar reflection.
    /// Avoid nested blur targets: if an ancestor already blurs the whole scene,
    /// the mask is emitted into that target and participates in its blur.
    func withSpatialBlur(
        frame: CanvasFrame, radius: Float, body: () -> Void
    ) {
        guard radius > 0, !insideBlurScope else { body(); return }
        beginContentBlur(
            x: frame.x, y: frame.y, w: frame.w, h: frame.h, radius: radius
        )
        body()
        endContentBlur()
    }

    /// Run `body` inside optional blur bookends, of whichever kind the node asked
    /// for.
    ///
    /// Scopes do not nest, in either kind or across them. Each one costs a
    /// render-target switch and reads back what the previous one composited, so
    /// an inner scope would blur the outer one's output a second time. The
    /// outermost wins — which is also what lets an overlay hoist its content's
    /// backdrop scope up over the panel's own chrome.
    ///
    /// Content wins over backdrop on the same node: `.blur()` is a statement
    /// about this view, and a frosted backdrop under a view that is itself
    /// being softened is not something you can see.
    private func withBlurScope(
        content contentRadius: Float?,
        backdrop backdropRadius: Float?,
        x: Float, y: Float, w: Float, h: Float,
        cornerRadius: Float = 0,
        body: () -> Void
    ) {
        guard w > 0, h > 0, !insideBlurScope else { return body() }

        if let radius = contentRadius, radius > 0 {
            insideBlurScope = true
            beginContentBlur(x: x, y: y, w: w, h: h, radius: radius)
            body()
            endContentBlur()
            insideBlurScope = false
        } else if let radius = backdropRadius, radius > 0 {
            insideBlurScope = true
            beginBackdropBlur(
                x: x, y: y, w: w, h: h, radius: radius,
                cornerRadius: cornerRadius
            )
            body()
            endBackdropBlur()
            insideBlurScope = false
        } else {
            body()
        }
    }

    /// Scissor children to a box (`.clipped()`). Overlays collected during the
    /// walk still emit after the tree with an empty clip stack, so a menubar
    /// dropdown is not trapped inside the strip.
    private func withContentClip(
        _ enabled: Bool,
        x: Float, y: Float, w: Float, h: Float,
        body: () -> Void
    ) {
        guard enabled, w > 0, h > 0 else {
            body()
            return
        }
        let viewCull = CullRect(x0: x, y0: y, x1: x + w, y1: y + h)
        let nextCull = cull.intersection(viewCull)
        if nextCull.isEmpty { return }
        pushClip(x: x, y: y, w: w, h: h)
        cullStack.append(nextCull)
        body()
        cullStack.removeLast()
        popClip()
    }

    // MARK: - Tree emission (pre-order DFS = paint order)

    /// Emit chrome from a laid-out retained tree.
    /// `originX/Y` shift the tree (e.g. below ImGui menu). Viewport seeds the
    /// cull stack; `ScrollView` further intersects so long lists skip off-screen
    /// subtrees entirely (not only leaves).
    public func emitTree(
        _ root: any AnyViewNode,
        originX: Float = 0,
        originY: Float = 0,
        viewportW: Float,
        viewportH: Float
    ) {
        pendingOverlays.removeAll(keepingCapacity: true)
        cullStack.removeAll(keepingCapacity: true)
        cullStack.append(CullRect(x0: 0, y0: 0, x1: viewportW, y1: viewportH))
        retainedShift = (0, 0)
        NodeVisibility.beginFrame()
        WidgetProfiler.beginFrame()
        // Here rather than at the loop's `advanceFrame()`: this is the one
        // place that knows a wake turned into drawing, and scene ids age on
        // passes that draw. See `SceneNodeIdentity`.
        SceneNodeIdentity.noteEmitPass()
        emitNode(root, ox: originX, oy: originY)

        // After the main walk, so overlays paint above everything and — because
        // the clip stack is balanced by now — are not scissored by whatever
        // ancestor the presenter happened to sit inside.
        for pending in pendingOverlays {
            let att = pending.attachment
            att.layoutAndPlace(
                anchorX: pending.x, anchorY: pending.y,
                anchorW: pending.w, anchorH: pending.h,
                viewportW: viewportW, viewportH: viewportH
            )
            guard let overlayRoot = att.root else { continue }

            // A glass overlay must frost what is *behind* the panel, not the
            // panel's own chrome, so the capture has to happen before any of it.
            // Hoisting the scope up here does that; `withBlurScope` then
            // no-ops the scope the content node would have opened.
            //
            // One level down is where a collapsed `.blur()` lands, because the
            // shell wraps exactly one mounted content node. Behind a fragment
            // (a tuple, an `if`) it stays where it was.
            let glassChild = overlayRoot.childNodes.first as? YogaBoxNode
            let glassRadius = overlayRoot.backdropBlurRadius
                ?? glassChild?.backdropBlurRadius

            // Which shape the frost is cut to. Normally the panel's own, since
            // the frost rect *is* the panel — but a "transparent shell" panel
            // (no fill, no padding, the pattern for putting the glass on the
            // content instead) draws nothing itself, and there the visible
            // surface is the child. Cutting to the panel then leaves frost
            // outside the only rounded thing on screen.
            let shellIsBare = (overlayRoot.fillColor?.a ?? 0) <= 0
                && overlayRoot.padding == .zero
            let glassCorner = shellIsBare
                ? (cornerRadius(of: glassChild) ?? att.cornerRadius)
                : att.cornerRadius

            withBlurScope(
                content: nil, backdrop: glassRadius,
                x: att.origin.x, y: att.origin.y, w: att.size.w, h: att.size.h,
                cornerRadius: glassCorner
            ) {
                // Outline first, one pixel proud on every side, so the panel's
                // own fill covers the middle of it — which is exactly why a
                // glass panel gets none. A plate is not a stroke: under a
                // translucent fill its middle shows through as a flat wash, and
                // it would be the only thing the blur had to capture. Until the
                // SDF pipeline can stroke a rounded rect, a frosted panel's
                // edge comes from its own fill and corner radius.
                if let border = att.border, glassRadius == nil {
                    roundedRect(
                        x: att.origin.x - 1, y: att.origin.y - 1,
                        w: att.size.w + 2, h: att.size.h + 2,
                        color: border, radius: att.cornerRadius + 1
                    )
                }
                // Overlays get a fresh cull of the full viewport so a popup
                // is not discarded just because its anchor was inside a
                // scrolled-away region that tightened the main-walk cull.
                let savedCull = cullStack
                cullStack = [CullRect(x0: 0, y0: 0, x1: viewportW, y1: viewportH)]
                emitNode(
                    overlayRoot,
                    ox: att.origin.x, oy: att.origin.y
                )
                cullStack = savedCull
            }
        }
        pendingOverlays.removeAll(keepingCapacity: true)
        cullStack.removeAll(keepingCapacity: true)
        WidgetProfiler.endFrame()
    }

    /// A node's corner radius, wherever it happens to keep it.
    ///
    /// Three classes declare their own rather than sharing one on the base, so
    /// asking the question needs all three names. Same shape as the fill
    /// branches in `applyViewStyle`.
    private func cornerRadius(of node: (any AnyViewNode)?) -> Float? {
        if let leaf = node as? LeafNode { return leaf.cornerRadius }
        if let stack = node as? StackNode { return stack.cornerRadius }
        if let box = node as? StyleBoxNode { return box.cornerRadius }
        return nil
    }

    private struct PendingOverlay {
        let attachment: OverlayAttachment
        let x: Float
        let y: Float
        let w: Float
        let h: Float
    }

    private func emitNode(
        _ node: any AnyViewNode,
        ox: Float, oy: Float
    ) {
        // Hidden: mounted, not drawn. Yoga has already skipped it, so its
        // children still carry whatever frames they had when it was last
        // visible — walking in would draw the pane where it used to be. See
        // `View.hidden(_:)`.
        if let box = node as? YogaBoxNode, box.isHidden { return }

        // A transitioning subtree is drawn faded and displaced. Wrapping the
        // whole walk means every primitive underneath inherits it without
        // knowing anything about transitions, and nesting multiplies.
        if let box = node as? YogaBoxNode,
           let transition = box.transitionState,
           transition.isTransitioning
        {
            let saved = alphaMultiplier
            alphaMultiplier *= transition.alpha
            let shift = transition.translation
            emitNodeBody(node, ox: ox + shift.x, oy: oy + shift.y)
            alphaMultiplier = saved
            return
        }
        emitNodeBody(node, ox: ox, oy: oy)
    }

    private func emitNodeBody(
        _ node: any AnyViewNode,
        ox: Float, oy: Float
    ) {
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let x = ox + YGNodeLayoutGetLeft(yref)
            let y = oy + YGNodeLayoutGetTop(yref)
            let w = YGNodeLayoutGetWidth(yref)
            let h = YGNodeLayoutGetHeight(yref)

            // Recorded here rather than emitted here: this is the one place
            // that knows the presenter's absolute rect, but drawing at this
            // point would put the popup underneath every later sibling.
            // Always register, even if the anchor is culled — the popup may
            // still sit on-screen after placement.
            if let presenter = node as? OverlayBoxNode, presenter.attachment.presented {
                // Anchored where the presenter will be *seen*, not where it is
                // emitted — see `retainedShift`.
                pendingOverlays.append(
                    PendingOverlay(
                        attachment: presenter.attachment,
                        x: x - retainedShift.x, y: y - retainedShift.y,
                        w: w, h: h
                    )
                )
            }

            if let scroll = node as? ScrollNode {
                // Record what Yoga granted; clamping against the requested size
                // would let content scroll out of reach.
                scroll.viewportLength = scroll.axis == .vertical ? h : w
                scroll.contentLength = scroll.measureContentLength()
                // The renderer owns the transform and clip. Swift keeps only
                // its last reported offset so virtualization/culling can emit
                // the right content; applying it to commands here as well
                // would move the subtree twice.
                //
                // One consequence: this cull is in the node's *content*
                // coordinates while every cull above it is in window
                // coordinates, so the two cannot be intersected and this
                // replaces the stack rather than narrowing it. Ancestor
                // clipping is not lost — it moved to the renderer's scissor.
                let span = scroll.paintedSpan()
                let viewCull: CullRect
                switch scroll.axis {
                case .vertical:
                    viewCull = CullRect(
                        x0: x, y0: y + span.top,
                        x1: x + w, y1: y + span.bottom
                    )
                case .horizontal:
                    // Everything along the scroll axis. `EndNode` carries one
                    // span and the renderer reads it as vertical, so a
                    // horizontal container has no way to *say* it drew a
                    // window — and a claim it cannot make is one it must not
                    // rely on. Drawing all of it makes the silence true.
                    viewCull = CullRect(
                        x0: x, y0: y,
                        x1: x + max(w, scroll.contentLength), y1: y + h
                    )
                }
                if viewCull.isEmpty { return }
                NodeVisibility.mark(scroll.id)

                let flags: SceneNodeFlags = scroll.axis == .vertical
                    ? [.clip, .scrollY, .absoluteCoordinates]
                    : [.clip, .scrollX, .absoluteCoordinates]
                beginNode(scroll.id, x: x, y: y, w: w, h: h, flags: flags)
                if let request = scroll.revealRequest {
                    scrollNode(to: request.offset, serial: request.serial)
                }
                cullStack.append(viewCull)
                // The renderer will subtract this from everything below, so
                // anything recorded here for later emission has to know.
                let shift = scroll.childOffset
                retainedShift.x += shift.x
                retainedShift.y += shift.y
                for c in scroll.childNodes {
                    emitNode(c, ox: x, oy: y)
                }
                retainedShift.x -= shift.x
                retainedShift.y -= shift.y
                cullStack.removeLast()
                // The span goes back with the extent, from the same
                // computation that culled — see `ScrollNode.paintedSpan`. A
                // horizontal container reports nothing, which the wire format
                // reads as "all of it", which is what it just drew.
                endNode(
                    contentW: scroll.axis == .horizontal ? scroll.contentLength : w,
                    contentH: scroll.axis == .vertical ? scroll.contentLength : h,
                    emittedTop: scroll.axis == .vertical ? span.top : 0,
                    emittedBottom: scroll.axis == .vertical ? span.bottom : 0
                )

                if scroll.showsIndicator, scroll.maxOffset > 0 {
                    emitScrollIndicator(scroll, x: x, y: y, w: w, h: h)
                }
                return
            }

            // Subtree skip: if this box misses the current cull rect, nothing
            // under it can paint (scroll content is already under a tight cull;
            // window-level stacks rarely overflow their Yoga frame in paint).
            if !cull.intersects(x: x, y: y, w: w, h: h) {
                return
            }
            NodeVisibility.mark(box.id)

            if let styled = node as? StyleBoxNode {
                withBlurScope(
                    content: styled.contentBlurRadius,
                    backdrop: styled.backdropBlurRadius,
                    x: x, y: y, w: w, h: h,
                    cornerRadius: styled.cornerRadius
                ) {
                    let interactive = styled.hoverFill != nil
                    let flags = nodeFlags(
                        for: styled.id, interactive: interactive
                    )
                    if let flags {
                        beginNode(styled.id, x: x, y: y, w: w, h: h, flags: flags)
                    }
                    if let g = styled.fillGradient {
                        linearGradientRect(
                            x: x, y: y, w: w, h: h, from: g.from, to: g.to,
                            angle: g.angle, radius: styled.cornerRadius
                        )
                    } else if let fill = styled.fillColor {
                        if styled.cornerRadius > 0 {
                            roundedRect(
                                x: x, y: y, w: w, h: h,
                                color: fill, radius: styled.cornerRadius
                            )
                        } else {
                            rect(x: x, y: y, w: w, h: h, color: fill)
                        }
                    }
                    withContentClip(styled.clipsContent, x: x, y: y, w: w, h: h) {
                        for c in styled.childNodes {
                            emitNode(c, ox: x, oy: y)
                        }
                    }
                    if flags != nil {
                        endNode(
                            contentW: w, contentH: h,
                            hoverTint: hoverTint(
                                base: styled.fillColor, target: styled.hoverFill
                            ),
                            cornerRadius: styled.cornerRadius
                        )
                    }
                }
                return
            }

            if let stack = node as? StackNode {
                withBlurScope(
                    content: stack.contentBlurRadius,
                    backdrop: stack.backdropBlurRadius,
                    x: x, y: y, w: w, h: h,
                    cornerRadius: stack.cornerRadius
                ) {
                    let flags = nodeFlags(
                        for: stack.id, interactive: stack.isRendererInteractive
                    )
                    if let flags {
                        beginNode(stack.id, x: x, y: y, w: w, h: h, flags: flags)
                    }
                    let fill = stack.fillColor
                    if let g = stack.fillGradient {
                        linearGradientRect(
                            x: x, y: y, w: w, h: h, from: g.from, to: g.to,
                            angle: g.angle, radius: stack.cornerRadius
                        )
                    } else if let fill {
                        if stack.cornerRadius > 0 {
                            roundedRect(
                                x: x, y: y, w: w, h: h,
                                color: fill, radius: stack.cornerRadius
                            )
                        } else {
                            rect(x: x, y: y, w: w, h: h, color: fill)
                        }
                    }
                    withContentClip(stack.clipsContent, x: x, y: y, w: w, h: h) {
                        for c in stack.childNodes {
                            emitNode(c, ox: x, oy: y)
                        }
                    }
                    if flags != nil {
                        endNode(
                            contentW: w, contentH: h,
                            hoverTint: hoverTint(base: fill, target: stack.hoverFill),
                            cornerRadius: stack.cornerRadius
                        )
                    }
                }
                return
            }

            if let leaf = node as? LeafNode {
                withBlurScope(
                    content: leaf.contentBlurRadius,
                    backdrop: leaf.backdropBlurRadius,
                    x: x, y: y, w: w, h: h,
                    cornerRadius: leaf.cornerRadius
                ) {
                    let interaction = interactionTints(for: leaf)
                    let flags = nodeFlags(for: leaf.id, interactive: interaction.isInteractive)
                    if let flags {
                        beginNode(leaf.id, x: x, y: y, w: w, h: h, flags: flags)
                    }
                    WidgetProfiler.measure(leaf.agentId ?? leaf.label) {
                        emitLeafContents(leaf, x: x, y: y, w: w, h: h)
                    }
                    if flags != nil {
                        endNode(
                            contentW: w, contentH: h,
                            hoverTint: interaction.hover,
                            pressTint: interaction.press,
                            cornerRadius: leaf.cornerRadius
                        )
                    }
                }
                return
            }

            for c in node.childNodes {
                emitNode(c, ox: x, oy: y)
            }
            return
        }

        // Fragments have no box of their own — always walk children.
        for c in node.childNodes {
            emitNode(c, ox: ox, oy: oy)
        }
    }

    /// Paint for a leaf inside an optional backdrop-blur scope.
    /// Flags for a node worth telling the renderer about, or nil for one that
    /// is not.
    ///
    /// Two unrelated reasons to open a node, which is why they are decided in
    /// one place: the renderer draws the interaction feedback, and the
    /// renderer arbitrates the wheel. A widget with wheel behaviour of its own
    /// needs to be visible to that arbitration even when it paints no tint and
    /// hover means nothing to it — otherwise the renderer sees only the scroll
    /// container enclosing it, scrolls that, and the widget's handler never
    /// runs. A `Scene3D` inside a `ScrollView` is the case that shows it: the
    /// wheel is supposed to move the camera.
    private func nodeFlags(for id: NodeID, interactive: Bool) -> SceneNodeFlags? {
        let claimsWheel = ScrollRouter.claimsWheel(id)
        guard interactive || claimsWheel else { return nil }
        var flags: SceneNodeFlags = [.absoluteCoordinates]
        if interactive { flags.insert(.hitTest) }
        if claimsWheel { flags.insert(.wheel) }
        return flags
    }

    /// Returns the smallest source-over tint that turns a uniform `base` into
    /// `target`. Keeping its alpha minimal also disturbs foreground glyphs as
    /// little as possible when the renderer lays the interaction tint over the
    /// complete retained node.
    private func interactionTint(from base: Color, to target: Color) -> Color {
        let channels = [(base.r, target.r), (base.g, target.g), (base.b, target.b)]
        var alpha: Float = 0
        for (b, t) in channels {
            let required = t >= b
                ? (b < 1 ? (t - b) / (1 - b) : 0)
                : (b > 0 ? (b - t) / b : 0)
            alpha = max(alpha, required)
        }
        alpha = min(max(alpha, 1 / 255), 1)
        func source(_ b: Float, _ t: Float) -> Float {
            min(max(0, (t - (1 - alpha) * b) / alpha), 1)
        }
        return Color(
            r: source(base.r, target.r),
            g: source(base.g, target.g),
            b: source(base.b, target.b),
            a: alpha * target.a
        )
    }

    private func hoverTint(base: Color?, target: Color?) -> Color? {
        guard let target else { return nil }
        // A fully transparent fill is not a colour — `.background(.clear)`
        // is how an open-state chip turns off, and treating it as black
        // made the hover tint a dark slab.
        guard let base, base.a > 0.01 else {
            return target.opacity(min(max(target.a, 0.01), 0.18))
        }
        return interactionTint(from: base, to: target)
    }

    private func interactionTints(
        for leaf: LeafNode
    ) -> (isInteractive: Bool, hover: Color?, press: Color?) {
        if leaf.kind == .button, let style = leaf.buttonStyle, leaf.isEnabled {
            return (true,
                    interactionTint(from: style.background, to: style.hover),
                    interactionTint(from: style.background, to: style.pressed))
        }
        return (
            leaf.isRendererInteractive,
            hoverTint(base: leaf.fillColor, target: leaf.hoverFill),
            nil
        )
    }

    private func emitLeafContents(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        // Hover wins over the base fill; both honour the radius.
        let leafFill = leaf.fillColor
        if let g = leaf.fillGradient {
            linearGradientRect(
                x: x, y: y, w: w, h: h, from: g.from, to: g.to,
                angle: g.angle, radius: leaf.cornerRadius
            )
        } else if let fill = leafFill {
            if leaf.cornerRadius > 0 {
                roundedRect(
                    x: x, y: y, w: w, h: h,
                    color: fill, radius: leaf.cornerRadius
                )
            } else {
                rect(x: x, y: y, w: w, h: h, color: fill)
            }
        }
        if (leaf.kind == .text || leaf.kind == .markdown), !leaf.text.isEmpty {
            let textColor = leaf.color
            // Multi-line: emit one command per wrapped line (same breaks
            // as Yoga measure via TextLayoutCache / Font::wrapLines).
            // `measureForYoga` reserves a built-in 4px horizontal / 2px
            // vertical inset, and Yoga adds modifier padding around that
            // measured content. Painting must apply the same offsets; using
            // the outer box origin put glyphs at its top-left and left all
            // padding on the bottom/right (most visible on hover fills).
            let lineH = (leaf.font ?? FontStore.default)?.lineHeight ?? 18
            let lines = leaf.cachedLines.isEmpty ? [leaf.text] : leaf.cachedLines
            let textX = x + leaf.padding.leading
            let textY = y + leaf.padding.top + 2
            var searchStart = leaf.text.startIndex
            for (i, line) in lines.enumerated() {
                let ly = textY + Float(i) * lineH
                if leaf.kind == .markdown, let style = leaf.markdownStyle,
                   let range = leaf.text.range(of: line, range: searchStart..<leaf.text.endIndex)
                {
                    let offset = leaf.text.distance(from: leaf.text.startIndex, to: range.lowerBound)
                    emitMarkdownLine(
                        line, documentOffset: offset, spans: leaf.markdownSpans,
                        style: style, font: leaf.font, x: textX, y: ly, h: lineH
                    )
                    searchStart = range.upperBound
                } else {
                    text(
                        line, x: textX, y: ly, w: w, h: lineH,
                        color: textColor, font: leaf.font
                    )
                }
            }
        }
        if leaf.kind == .button {
            let style = leaf.buttonStyle ?? ButtonStyle()
            let fill = leaf.isEnabled ? style.background : style.disabledBackground
            roundedRect(
                x: x, y: y, w: w, h: h,
                color: fill, radius: leaf.cornerRadius
            )
            if !leaf.text.isEmpty, let f = leaf.font ?? FontStore.default {
                let lineH = f.lineHeight
                let labelW = f.shapedRun(leaf.text).width
                let ink = f.inkBounds(leaf.text)
                // `text()` adds its historical 4px pen inset. Prefer the
                // visible bitmap bounds for compact symbols; ordinary/fallback
                // text retains typographic line-box centering.
                let labelX = ink.map {
                    x + (w - $0.width) / 2 - $0.minX - 4
                } ?? (x + (w - labelW) / 2 - 4)
                let labelY = ink.map {
                    y + (h - $0.height) / 2 - f.ascent - $0.minY
                } ?? (y + max(0, (h - lineH) / 2))
                text(
                    leaf.text,
                    x: labelX,
                    y: labelY,
                    w: w, h: lineH, color: leaf.color, font: f
                )
            }
            return
        }

        if leaf.kind == .toggle {
            emitToggle(leaf, x: x, y: y, w: w, h: h)
            return
        }

        if leaf.kind == .slider {
            emitSlider(leaf, x: x, y: y, w: w, h: h)
            return
        }

        if leaf.kind == .canvas {
            let frame = CanvasFrame(x: x, y: y, w: w, h: h)
            // Two different frames, because they answer to two different
            // coordinate systems. Paint gets the emit frame: the renderer
            // moves the result, so painting where the node is *declared* is
            // right. `lastCanvasFrame` is what the gesture and wheel handlers
            // subtract from a window-space pointer, so it has to be where the
            // canvas is *seen* — see `retainedShift`.
            leaf.lastCanvasFrame = CanvasFrame(
                x: x - retainedShift.x, y: y - retainedShift.y, w: w, h: h
            )
            // App owns every command for this box (background, glyphs, bars…).
            leaf.canvasPaint?(self, frame)
            return
        }

        if leaf.kind == .scene3D {
            let frame = CanvasFrame(x: x, y: y, w: w, h: h)
            leaf.spatialRuntime?.emit(self, frame: frame)
            return
        }

        if leaf.kind == .divider, let style = leaf.dividerStyle {
            let t = max(1, style.thickness)
            // Rounded to a whole pixel: a 1px rule landing on a half
            // pixel is smeared across two rows by the SDF and reads as
            // a smudge rather than a line.
            if leaf.isVerticalDivider {
                rect(
                    x: (x + (w - t) / 2).rounded(), y: y,
                    w: t, h: h, color: style.color
                )
            } else {
                rect(
                    x: x, y: (y + (h - t) / 2).rounded(),
                    w: w, h: t, color: style.color
                )
            }
            return
        }

        if leaf.kind == .textField {
            emitTextField(leaf, x: x, y: y, w: w, h: h)
        }
        if leaf.kind == .editor {
            EditorProbe.measure("emit.total") {
                emitEditor(leaf, x: x, y: y, w: w, h: h)
            }
            // Outside the span, so the summary it may print is not counted as
            // part of the frame it is reporting on.
            EditorProbe.endFrame(
                chars: leaf.editing.text.utf8.count,
                rows: leaf.editing.layout.count
            )
        }
        if leaf.kind == .image {
            // A path-backed image resolves here rather than in `body`. Two
            // things fall out of that, both wanted: an image that arrives later
            // needs only a redraw, and — because this runs *after* the cull
            // test — only images the frame actually draws are ever requested,
            // so viewport gating is automatic instead of the app's job.
            var resolved = leaf.image
            if resolved == nil, let path = leaf.imagePath {
                resolved = ImageStore.imageIfLoaded(
                    path: path,
                    maxPixelSize: leaf.imageDecodePixels,
                    into: editor
                )
            }
            guard let img = resolved else {
                if let placeholder = leaf.imagePlaceholder {
                    if leaf.imagePlaceholderRadius > 0 {
                        roundedRect(
                            x: x, y: y, w: w, h: h,
                            color: placeholder, radius: leaf.imagePlaceholderRadius
                        )
                    } else {
                        rect(x: x, y: y, w: w, h: h, color: placeholder)
                    }
                }
                return
            }
            // Least-recently-*drawn*, not least-recently-requested: an image
            // held by a view that is scrolled away should age out, and one
            // being painted every frame must not.
            ImageStore.touch(img)
            let dest = imageDestRect(
                boxX: x, boxY: y, boxW: w, boxH: h,
                srcW: img.pixelWidth, srcH: img.pixelHeight,
                mode: leaf.imageContentMode
            )
            self.image(
                textureId: img.textureId,
                x: dest.x, y: dest.y, w: dest.w, h: dest.h,
                tint: leaf.imageTint
            )
        }
    }

    /// Layout box → dest rect for the bitmap under `contentMode`.
    private func imageDestRect(
        boxX: Float, boxY: Float, boxW: Float, boxH: Float,
        srcW: Float, srcH: Float,
        mode: ImageContentMode
    ) -> (x: Float, y: Float, w: Float, h: Float) {
        guard srcW > 0, srcH > 0, boxW > 0, boxH > 0 else {
            return (boxX, boxY, boxW, boxH)
        }
        switch mode {
        case .stretch:
            return (boxX, boxY, boxW, boxH)
        case .fit:
            let sx = boxW / srcW
            let sy = boxH / srcH
            let s = min(sx, sy)
            let dw = srcW * s
            let dh = srcH * s
            return (boxX + (boxW - dw) * 0.5, boxY + (boxH - dh) * 0.5, dw, dh)
        case .fill:
            let sx = boxW / srcW
            let sy = boxH / srcH
            let s = max(sx, sy)
            let dw = srcW * s
            let dh = srcH * s
            return (boxX + (boxW - dw) * 0.5, boxY + (boxH - dh) * 0.5, dw, dh)
        }
    }
}

extension DrawList {
    /// Draws a toggle as: capsule track, knob, then label.
    ///
    /// The knob position comes from the animation, never from `isOn` directly —
    /// reading the boolean would snap it, which is the whole thing the
    /// animation exists to avoid. `isOn` is only the fallback for a node that
    /// somehow has no animation yet.
    fileprivate func emitToggle(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let style = leaf.toggleStyle else { return }
        let trackH = style.trackHeight
        // The +4 mirrors the horizontal half of the padding `measureForYoga`
        // added, so the track sits where the box was sized for it.
        let trackX = x + 4
        let trackY = y + (h - trackH) / 2
        let track = leaf.toggleTrack?.current
            ?? style.track(on: leaf.isOn, hovered: false, enabled: leaf.isEnabled)
        roundedRect(
            x: trackX, y: trackY, w: style.trackWidth, h: trackH,
            color: track, radius: trackH / 2
        )

        let t = leaf.toggleKnob?.current ?? (leaf.isOn ? 1 : 0)
        let radius = trackH / 2 - style.knobInset
        // Travel is measured centre-to-centre, so the knob stays inset at both
        // ends regardless of how wide the track is.
        let travel = style.trackWidth - trackH
        circle(
            cx: trackX + trackH / 2 + travel * t,
            cy: trackY + trackH / 2,
            radius: radius,
            color: leaf.toggleKnobColor?.current
                ?? style.knobColor(over: track, enabled: leaf.isEnabled)
        )

        if !leaf.text.isEmpty, let font = leaf.font ?? FontStore.default {
            let lineH = font.lineHeight
            text(
                leaf.text,
                // -4 cancels the pen inset `text(_:)` applies.
                x: trackX + style.trackWidth + style.labelGap - 4,
                y: y + max(0, (h - lineH) / 2),
                w: w, h: lineH, color: leaf.color, font: font
            )
        }
    }

    /// Draws a slider as: inactive track, active track, knob, then readout.
    ///
    /// This is also where the drag geometry is recorded. Deriving it here
    /// rather than in the drag handler is what keeps the knob under the
    /// pointer: the numbers that convert a click back to a value are, by
    /// construction, the same ones that drew the track.
    fileprivate func emitSlider(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let style = leaf.sliderStyle else { return }
        let readoutW = leaf.text.isEmpty ? 0 : style.valueGap + style.valueWidth
        let knobR = style.knobRadius
        // The +4/-8 mirror the padding `measureForYoga` added.
        let trackX = x + 4
        let trackW = max(0, w - 8 - readoutW)
        let cy = y + h / 2

        // The knob's centre never reaches the track ends, so travel is shorter
        // than the track by one diameter.
        leaf.sliderInset = 4 + knobR
        leaf.sliderTravel = max(0, trackW - knobR * 2)

        let enabled = leaf.isEnabled
        let thickness = style.trackThickness
        roundedRect(
            x: trackX, y: cy - thickness / 2, w: trackW, h: thickness,
            color: enabled ? style.inactiveTrack : style.disabledTrack,
            radius: thickness / 2
        )

        let cx = trackX + knobR + leaf.sliderTravel * leaf.sliderFraction
        let filled = cx - trackX
        if filled > 0, enabled {
            roundedRect(
                x: trackX, y: cy - thickness / 2, w: filled, h: thickness,
                color: style.activeTrack, radius: thickness / 2
            )
        }

        circle(
            cx: cx, cy: cy,
            radius: knobR * (leaf.sliderKnobScale?.current ?? 1),
            color: enabled ? style.knob : style.disabledKnob
        )

        if !leaf.text.isEmpty, let font = leaf.font ?? FontStore.default {
            text(
                leaf.text,
                // -4 cancels the pen inset `text(_:)` applies.
                x: trackX + trackW + style.valueGap - 4,
                y: cy - font.lineHeight / 2,
                w: style.valueWidth, h: font.lineHeight,
                color: leaf.color, font: font
            )
        }
    }

    /// Focus chrome for a text field. The pipeline cannot stroke a rounded
    /// rect, so `.rounded` draws an outer plate in the ring colour and punches
    /// the field fill back on top — the same approach overlay borders use.
    fileprivate func emitFocusRing(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        let theme = leaf.theme
        let style = leaf.focusRingStyle ?? theme.focusRingStyle
        let bw = max(0.5, leaf.focusRingWidth ?? theme.focusRingWidth)
        let color = leaf.focusRingColor ?? theme.focusRingColor ?? theme.accent
        let fill = leaf.fillColor ?? theme.inset
        let radius = leaf.cornerRadius

        switch style {
        case .none:
            return
        case .underline:
            // Historical look: accent bars on the top and bottom edges only.
            rect(x: x, y: y, w: w, h: bw, color: color)
            rect(x: x, y: y + h - bw, w: w, h: bw, color: color)
        case .rectangle:
            rect(x: x, y: y, w: w, h: bw, color: color)
            rect(x: x, y: y + h - bw, w: w, h: bw, color: color)
            rect(x: x, y: y, w: bw, h: h, color: color)
            rect(x: x + w - bw, y: y, w: bw, h: h, color: color)
        case .rounded:
            if radius > 0 {
                roundedRect(x: x, y: y, w: w, h: h, color: color, radius: radius)
                let innerR = max(0, radius - bw)
                let iw = max(0, w - bw * 2)
                let ih = max(0, h - bw * 2)
                if iw > 0, ih > 0 {
                    roundedRect(
                        x: x + bw, y: y + bw, w: iw, h: ih,
                        color: fill, radius: innerR
                    )
                }
            } else {
                // Degenerate to a hard rectangle when the field is square.
                rect(x: x, y: y, w: w, h: bw, color: color)
                rect(x: x, y: y + h - bw, w: w, h: bw, color: color)
                rect(x: x, y: y, w: bw, h: h, color: color)
                rect(x: x + w - bw, y: y, w: bw, h: h, color: color)
            }
        }
    }

    /// Draws a field as: selection rects, then glyphs, then caret.
    ///
    /// That order is the whole point of the unified pipeline — under the old
    /// three-renderer split the caret was geometry and text always drew last,
    /// so a caret could never appear over its own glyphs.
    fileprivate func emitTextField(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let font = leaf.font ?? FontStore.default else { return }
        let inset = leaf.textInset
        let lineH = font.lineHeight
        let focused = FocusManager.isFocused(leaf.id)
        let state = leaf.editing
        let theme = leaf.theme

        if focused {
            emitFocusRing(leaf, x: x, y: y, w: w, h: h)
        }

        if state.text.isEmpty {
            if !leaf.placeholder.isEmpty {
                let top = leaf.isMultiline ? y + inset : y + max(0, (h - lineH) / 2)
                text(
                    leaf.placeholder, x: x + inset - 4, y: top,
                    w: w, h: lineH, color: theme.textMuted, font: font
                )
            }
            if focused, CaretBlink.isVisible {
                let top = leaf.isMultiline ? y + inset : y + max(0, (h - lineH) / 2)
                rect(
                    x: x + inset, y: top,
                    w: theme.caretWidth, h: lineH, color: theme.textPrimary
                )
            }
            return
        }

        // Single-line stays vertically centred in its box; multi-line starts
        // at the top inset and stacks.
        let firstTop = leaf.isMultiline ? y + inset : y + max(0, (h - lineH) / 2)
        let rows = state.layout.rows
        let selection = state.hasSelection ? state.selectedRange : nil
        let caretRow = state.layout.rowIndex(
            ofOffset: state.offset(of: state.focus), affinity: state.affinity
        )

        for (row, rowRange) in rows.enumerated() {
            let lineTop = firstTop + Float(row) * lineH
            // Same rule as the editor: draw only rows that fully fit, so a
            // shrunk box cannot spill text onto its neighbours.
            if lineTop + lineH > y + h { break }

            let lineStart = state.index(atOffset: rowRange.lowerBound)
            let lineEnd = state.index(atOffset: rowRange.upperBound)
            let lineText = String(state.text[lineStart..<lineEnd])
            let run = font.shapedRun(lineText)

            // Selection is a range over the whole buffer; clip it to this line
            // so each row draws only its own share.
            if let sel = selection, sel.lowerBound < lineEnd, sel.upperBound > lineStart {
                let from = max(sel.lowerBound, lineStart)
                let to = min(sel.upperBound, lineEnd)
                let x0 = run.caretX(for: localIndex(in: lineText, matching: from, lineStart: lineStart, state: state))
                let x1 = run.caretX(for: localIndex(in: lineText, matching: to, lineStart: lineStart, state: state))
                // A selection crossing a newline should show the break, so an
                // empty tail still paints a sliver.
                let spansNewline = sel.upperBound > lineEnd
                rect(
                    x: x + inset + x0, y: lineTop,
                    w: max(spansNewline ? 4 : 1, x1 - x0), h: lineH,
                    color: theme.selectionFill
                )
            }

            if !lineText.isEmpty {
                text(
                    lineText, x: x + inset - 4, y: lineTop,
                    w: w, h: lineH, color: leaf.color, font: font
                )
            }

            if focused, !state.hasSelection, CaretBlink.isVisible, row == caretRow {
                let local = localIndex(
                    in: lineText, matching: state.focus, lineStart: lineStart, state: state
                )
                rect(
                    x: x + inset + run.caretX(for: local), y: lineTop,
                    w: theme.caretWidth, h: lineH, color: theme.textPrimary
                )
            }
        }
    }

    /// Buffer index → index into a single line's own string, which is what
    /// `ShapedRun` (shaped per line) expects.
    fileprivate func localIndex(
        in lineText: String, matching index: String.Index,
        lineStart: String.Index, state: TextEditingState
    ) -> String.Index {
        let column = state.text.distance(from: lineStart, to: index)
        let clamped = max(0, min(column, lineText.count))
        return lineText.index(lineText.startIndex, offsetBy: clamped)
    }
}

extension DrawList {
    /// Draw order per row: current-line wash, search matches, selection,
    /// syntax-coloured text, caret. Backgrounds before glyphs, caret after —
    /// the ordering the unified pipeline made expressible.
    fileprivate func emitEditor(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let font = leaf.font ?? FontStore.default else { return }
        let style = leaf.codeStyle ?? CodeStyle()
        let inset = leaf.textInset
        let lineH = font.lineHeight
        let focused = FocusManager.isFocused(leaf.id)
        let state = leaf.editing
        let rows = state.layout.rows
        // Row == logical line here: EditorView always sets `wraps = false`
        // ("code editors scroll horizontally, not wrap"), so indexing the
        // cache by the same `row` used for `rows[row]` below is safe. A
        // wrapping editor would need this keyed by logical line instead.
        //
        // Gated on isStateful so the common rule-list (or no-highlighter)
        // case never pays for `state.lines` — a fresh O(length) split — on
        // every single emit. The cache itself no-ops for that case anyway;
        // this is what stops it from even trying every frame.
        if let highlighter = leaf.highlighter, highlighter.isStateful {
            EditorProbe.measure("emit.highlight") {
                leaf.highlightCache.update(lines: state.lines, with: highlighter)
            }
        }

        // Yoga may have shrunk the box below the measured height; the clamp
        // and the row window must use what was granted, not what was asked.
        leaf.viewportHeight = h
        leaf.textViewportWidth = max(0, w - leaf.gutterWidth - inset * 2)

        let textX = x + leaf.gutterWidth + inset - leaf.scrollX
        let top = y + inset - leaf.scrollY

        // Both cached on `leaf` against the exact `focus`/`affinity` they
        // were computed from — see `LeafNode.focusOffset()`/`focusRow()`.
        // `offset(of:)` walks the buffer from its start and `rowIndex` scans
        // every row; without this, a caret that hasn't moved still paid
        // both on every redraw a blink caused, indefinitely, for as long as
        // the editor stayed focused.
        let caretOffset = leaf.focusOffset()
        let caretRow = leaf.focusRow()
        let selection = state.hasSelection ? state.selectedRange : nil
        // Also once, not once per row a selection happens to span — the
        // value is the same every time.
        //
        // Unlike the caret above, these are *not* cached against the value
        // they were computed from, so they are two walks from the buffer's
        // start on every emit that has a selection at all.
        let selFromOffset = selection.map { sel in
            EditorProbe.measureOffset("emit.selStart") {
                state.offset(of: sel.lowerBound)
            }
        }
        let selToOffset = selection.map { sel in
            EditorProbe.measureOffset("emit.selEnd") {
                state.offset(of: sel.upperBound)
            }
        }

        // Only rows intersecting the viewport are emitted: a long buffer costs
        // a screenful of quads, not a file's worth.
        let firstRow = max(0, Int(leaf.scrollY / lineH))
        let lastRow = min(rows.count - 1, Int((leaf.scrollY + h) / lineH) + 1)
        guard firstRow <= lastRow else { return }

        // Pass 1 — chrome that must not scroll horizontally. The gutter stays
        // pinned while text moves under it, which is the whole reason this is
        // two clip regions instead of one.
        pushClip(x: x, y: y, w: w, h: h)
        if leaf.showsGutter, leaf.gutterWidth > 0 {
            rect(x: x, y: y, w: leaf.gutterWidth, h: h, color: style.gutterBackground)
        }
        for row in firstRow...lastRow {
            let rowTop = top + Float(row) * lineH
            if focused, row == caretRow, selection == nil {
                rect(
                    x: x + leaf.gutterWidth, y: rowTop,
                    w: w - leaf.gutterWidth, h: lineH, color: style.currentLine
                )
            }
            if leaf.showsGutter, leaf.gutterWidth > 0 {
                // Right-aligned so numbers stay in a column as they widen.
                let label = String(row + 1)
                let labelW = font.shapedRun(label).width
                text(
                    label, x: x + leaf.gutterWidth - inset - labelW - 4, y: rowTop,
                    w: leaf.gutterWidth, h: lineH,
                    color: style.gutterText, font: font
                )
                if !leaf.decorations.isEmpty {
                    let rowRange = rows[row]
                    // Worst severity wins the gutter glyph when a row has more
                    // than one — matches how IDEs collapse multiple markers.
                    if let deco = leaf.decorations
                        .filter({ $0.range.overlaps(rowRange) })
                        .min(by: { $0.severity.rank < $1.severity.rank })
                    {
                        text(
                            deco.resolvedGutterIcon, x: x + 2, y: rowTop,
                            w: inset * 2, h: lineH,
                            color: deco.resolvedColor, font: font
                        )
                    }
                }
            }
        }
        popClip()

        // Pass 2 — everything that scrolls, clipped to the text area so a
        // horizontally scrolled line cannot draw over the gutter.
        pushClip(
            x: x + leaf.gutterWidth, y: y,
            w: max(0, w - leaf.gutterWidth), h: h
        )
        defer { popClip() }

        // A running cursor, advanced by *relative* offset row to row, instead
        // of `state.index(atOffset:)` per row: that walks from the start of
        // the whole buffer every single call, so on a large file scrolled
        // any distance in, converting each visible row's bounds independently
        // cost the distance scrolled once *per row* — the difference between
        // one ~200ms stall and a few dozen microseconds, every redraw
        // (including just a blinking caret) for as long as the editor stayed
        // focused. Paying that walk once, to reach the first visible row,
        // and advancing by each row's own length from there, is the standard
        // fix for sequential `String.Index` access.
        // Anchored (`LeafNode.textIndex(atOffset:)` carries the last index it
        // resolved), so this is cheap while scrolling and expensive on the
        // first frame after a jump. Watching it is how the anchor is known to
        // still be doing its job.
        var cursor = EditorProbe.measure(
            "emit.rowWindow", at: rows[firstRow].lowerBound
        ) {
            leaf.textIndex(atOffset: rows[firstRow].lowerBound)
        }
        var cursorOffset = rows[firstRow].lowerBound

        for row in firstRow...lastRow {
            let range = rows[row]
            let rowTop = top + Float(row) * lineH

            if range.lowerBound > cursorOffset {
                cursor = state.text.index(cursor, offsetBy: range.lowerBound - cursorOffset)
            }
            let lo = cursor
            let hi = state.text.index(lo, offsetBy: range.upperBound - range.lowerBound)
            cursor = hi
            cursorOffset = range.upperBound

            let lineText = String(state.text[lo..<hi])
            let run = font.shapedRun(lineText)

            func columnX(_ column: Int) -> Float {
                let clamped = max(0, min(column, lineText.count))
                return run.caretX(for: lineText.index(lineText.startIndex, offsetBy: clamped))
            }

            for (i, match) in leaf.search.matches.enumerated() {
                guard match.lowerBound < range.upperBound,
                      match.upperBound > range.lowerBound else { continue }
                let a = columnX(match.lowerBound - range.lowerBound)
                let b = columnX(match.upperBound - range.lowerBound)
                let isCurrent = leaf.search.currentIndex == i
                rect(
                    x: textX + a, y: rowTop, w: max(2, b - a), h: lineH,
                    color: isCurrent ? style.currentSearchMatch : style.searchMatch
                )
            }

            if let sel = selection, let selFromOffset, let selToOffset,
               sel.lowerBound < hi, sel.upperBound > lo
            {
                let from = max(selFromOffset, range.lowerBound)
                let to = min(selToOffset, range.upperBound)
                let a = columnX(from - range.lowerBound)
                let b = columnX(to - range.lowerBound)
                let spansNewline = selToOffset > range.upperBound
                rect(
                    x: textX + a, y: rowTop,
                    w: max(spansNewline ? 4 : 1, b - a), h: lineH,
                    color: leaf.theme.selectionFill
                )
            }

            let lineSpans: [HighlightSpan]
            if let highlighter = leaf.highlighter {
                lineSpans = highlighter.isStateful
                    ? leaf.highlightCache.spans(atRow: row)
                    : highlighter.spans(in: lineText)
            } else {
                lineSpans = []
            }
            emitCodeLine(
                lineText, spans: lineSpans,
                style: style, run: run, font: font, x: textX, y: rowTop, h: lineH
            )

            for deco in leaf.decorations where deco.underline != .none && deco.range.overlaps(range) {
                let from = max(deco.range.lowerBound, range.lowerBound)
                let to = min(deco.range.upperBound, range.upperBound)
                guard from < to else { continue }
                emitUnderline(
                    deco.underline, color: deco.resolvedColor,
                    x0: textX + columnX(from - range.lowerBound),
                    x1: textX + columnX(to - range.lowerBound),
                    y: rowTop + lineH - 2
                )
            }

            if focused, !state.hasSelection, CaretBlink.isVisible, row == caretRow {
                let column = caretOffset - range.lowerBound
                rect(
                    x: textX + columnX(column), y: rowTop,
                    w: leaf.theme.caretWidth, h: lineH, color: leaf.theme.textPrimary
                )
            }
        }
    }

    /// Underline beneath a decorated span. `wavy` has no dedicated curve
    /// primitive — it is a handful of short `line()` zigzags, cheap enough
    /// per decorated span not to need one.
    private func emitUnderline(
        _ style: DecorationUnderline, color: Color, x0: Float, x1: Float, y: Float
    ) {
        switch style {
        case .none:
            return
        case .straight:
            line(x1: x0, y1: y, x2: x1, y2: y, color: color, width: 1.5)
        case .wavy:
            let period: Float = 4
            let amplitude: Float = 1.5
            var x = x0
            var up = true
            while x < x1 {
                let nx = min(x1, x + period)
                line(
                    x1: x, y1: y + (up ? 0 : amplitude),
                    x2: nx, y2: y + (up ? amplitude : 0),
                    color: color, width: 1
                )
                x = nx
                up.toggle()
            }
        }
    }

    /// Emits one line as coloured segments.
    ///
    /// Each segment is shaped on its own, so shaping does not carry across a
    /// span boundary — a ligature spanning a keyword edge would break. That is
    /// the same trade every token-colouring editor makes, and it only shows on
    /// text where a ligature straddles two token types.
    private func emitCodeLine(
        _ line: String, spans: [HighlightSpan], style: CodeStyle,
        run: ShapedRun, font: UIFont, x: Float, y: Float, h: Float
    ) {
        guard !line.isEmpty else { return }
        guard !spans.isEmpty else {
            text(line, x: x - 4, y: y, w: 10_000, h: h, color: style.text, font: font)
            return
        }

        func slice(_ r: Range<Int>) -> String {
            let a = line.index(line.startIndex, offsetBy: max(0, min(r.lowerBound, line.count)))
            let b = line.index(line.startIndex, offsetBy: max(0, min(r.upperBound, line.count)))
            return String(line[a..<b])
        }
        func xFor(_ column: Int) -> Float {
            let c = max(0, min(column, line.count))
            return run.caretX(for: line.index(line.startIndex, offsetBy: c))
        }

        var cursor = 0
        for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if span.range.lowerBound > cursor {
                let plain = slice(cursor..<span.range.lowerBound)
                text(
                    plain, x: x + xFor(cursor) - 4, y: y, w: 10_000, h: h,
                    color: style.text, font: font
                )
            }
            text(
                slice(span.range), x: x + xFor(span.range.lowerBound) - 4, y: y,
                w: 10_000, h: h, color: style.color(for: span.styleIndex), font: font
            )
            cursor = max(cursor, span.range.upperBound)
        }
        if cursor < line.count {
            text(
                slice(cursor..<line.count), x: x + xFor(cursor) - 4, y: y,
                w: 10_000, h: h, color: style.text, font: font
            )
        }
    }

    /// Emits a wrapped Markdown row using document-relative character spans.
    private func emitMarkdownLine(
        _ line: String, documentOffset: Int, spans: [MarkdownSpan],
        style: MarkdownStyle, font explicitFont: UIFont?,
        x: Float, y: Float, h: Float
    ) {
        guard let font = explicitFont ?? FontStore.default, !line.isEmpty else { return }
        let run = font.shapedRun(line)
        let lineRange = documentOffset..<(documentOffset + line.count)

        func slice(_ range: Range<Int>) -> String {
            let lo = line.index(line.startIndex, offsetBy: max(0, min(range.lowerBound, line.count)))
            let hi = line.index(line.startIndex, offsetBy: max(0, min(range.upperBound, line.count)))
            return String(line[lo..<hi])
        }
        func xFor(_ column: Int) -> Float {
            let index = line.index(line.startIndex, offsetBy: max(0, min(column, line.count)))
            return run.caretX(for: index)
        }

        var cursor = 0
        for span in spans {
            let lo = max(span.range.lowerBound, lineRange.lowerBound)
            let hi = min(span.range.upperBound, lineRange.upperBound)
            guard lo < hi else { continue }
            let local = (lo - documentOffset)..<(hi - documentOffset)
            if local.lowerBound > cursor {
                text(
                    slice(cursor..<local.lowerBound), x: x + xFor(cursor) - 4,
                    y: y, w: 10_000, h: h, color: style.text, font: font
                )
            }
            text(
                slice(local), x: x + xFor(local.lowerBound) - 4,
                y: y, w: 10_000, h: h, color: style.color(for: span.style), font: font
            )
            cursor = max(cursor, local.upperBound)
        }
        if cursor < line.count {
            text(
                slice(cursor..<line.count), x: x + xFor(cursor) - 4,
                y: y, w: 10_000, h: h, color: style.text, font: font
            )
        }
    }
}

extension DrawList {
    /// A thin position indicator, drawn outside the clip so it is never
    /// scrolled away with the content it describes.
    fileprivate func emitScrollIndicator(
        _ scroll: ScrollNode, x: Float, y: Float, w: Float, h: Float
    ) {
        let thickness: Float = 4
        let track = scroll.viewportLength
        guard track > 0, scroll.contentLength > 0 else { return }

        let ratio = min(1, track / scroll.contentLength)
        let thumb = max(24, track * ratio)
        let travel = track - thumb
        let progress = scroll.maxOffset > 0 ? scroll.scrollOffset / scroll.maxOffset : 0
        let along = travel * min(1, max(0, progress))

        let color = Color(
            r: scroll.theme.textSecondary.r,
            g: scroll.theme.textSecondary.g,
            b: scroll.theme.textSecondary.b,
            a: 0.55
        )
        if scroll.axis == .vertical {
            roundedRect(
                x: x + w - thickness - 2, y: y + along,
                w: thickness, h: thumb, color: color, radius: thickness / 2
            )
        } else {
            roundedRect(
                x: x + along, y: y + h - thickness - 2,
                w: thumb, h: thickness, color: color, radius: thickness / 2
            )
        }
    }
}
