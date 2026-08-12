#pragma once

// Authoritative POD draw-list command (C ABI layout). Swift imports this
// struct; do not redefine it on the Swift side.
//
// Fixed 32-byte stride for a simple pointer+count boundary.

#include <cstddef>
#include <cstdint>

namespace canvas {

/// Whether `CANVAS_TRACE_FRAMES` is set: log what a frame contained and what
/// the renderer could not resolve in it.
///
/// One switch for both because they are one question. A frame that draws less
/// than it should has two candidate explanations — it did not arrive, or it
/// arrived and something in it was dropped — and the only way to tell them
/// apart is to see the counts next to the drops. Both sites are otherwise
/// silent on purpose, which is correct and is exactly what makes them hard to
/// diagnose across a process boundary.
bool traceFrames();

enum class DrawCommandKind : uint32_t {
  Rect = 0,
  RoundedRect = 1,
  Text = 2,       // param = first glyph index, w = glyph count
  Circle = 3,     // aux = radius; x,y = center
  Line = 4,       // x,y = p0; w,h = p1
  PushClip = 5,   // x,y,w,h = scissor rect
  PopClip = 6,
  /// Textured quad. param = TextureManager id; x,y,w,h = dest rect; color = tint.
  Image = 7,
  /// Backdrop blur barrier. Flushes UI drawn so far, captures the main target
  /// in x,y,w,h, blurs it, and composites the result. Children/chrome after
  /// this draw sharp on top. `aux` = blur radius in pixels (clamped in engine).
  ///
  /// `param` = corner radius of the surface the frost sits under, in whole
  /// pixels; 0 is square. The composite has to be told, because it is drawn
  /// *under* the panel's own fill and so is the one part of a rounded glass
  /// panel that the fill cannot cover — square corners on it show as bright
  /// tabs poking out from behind the shape.
  BeginBackdropBlur = 8,
  /// Closes a blur scope (bookkeeping / future nesting). No GPU work yet.
  EndBackdropBlur = 9,
  /// Content blur. Everything between Begin and End is drawn into an offscreen
  /// target instead of the frame, blurred, and composited back over the rect in
  /// x,y,w,h with its own alpha. `aux` = radius in pixels. Where backdrop blur
  /// frosts what is *behind* a view, this softens the view itself.
  BeginContentBlur = 10,
  EndContentBlur = 11,
  /// Filled arbitrary polygon (custom region — pie/donut wedges, etc.).
  /// param = first vertex index, w = vertex count, into the mesh-vertex side
  /// buffer (same pattern as Text/GlyphInstance). aux = 0 fans the vertices
  /// around vertex 0 (a solid wedge/star-convex shape); aux = 1 treats them
  /// as alternating inner/outer pairs and triangulates a ring strip between
  /// them (an annulus sector — the shape a donut chart needs, since a hole
  /// in the middle means there is no single point the whole boundary fans
  /// from).
  Mesh = 12,
  /// Connected 1px line strip. param = first vertex index, w = vertex count,
  /// into the same MeshVertex side buffer used by Mesh.
  Polyline = 13,
  /// Depth-tested triangles emitted by a LavaUI Scene3D. param = first
  /// SpatialVertex and w = vertex count (a multiple of three).
  SpatialTriangles = 14,
  /// Clears depth inside one Scene3D viewport before its triangles.
  SpatialBegin = 15,
  /// Opens a **scene node**: a named subtree the renderer can move without
  /// the producer's help.
  ///
  ///   param = node id, assigned by the producer and stable across frames
  ///   x, y  = local offset from the enclosing node
  ///   w, h  = viewport: the node's hit rect, and what it clips to when
  ///           `SceneNodeFlags::Clip` is set
  ///   color = `SceneNodeFlags` bitfield
  ///
  /// Bracketing rather than a separate node array, because the command list
  /// already works this way — `PushClip`/`PopClip` and the blur scopes are
  /// the same idea, and a node is those plus an identity. A renderer that
  /// ignored both kinds would draw exactly what it draws today, since a node
  /// with no offset is transparent.
  ///
  /// What the identity buys is state the *renderer* owns across frames:
  /// a scroll offset keyed by node id survives the producer republishing the
  /// list, which is what lets a window scroll while the app that drew it is
  /// stopped.
  BeginNode = 16,
  /// Closes the innermost open node.
  ///
  ///   x, y  = content extent
  ///   w, h  = the vertical span of content actually emitted, in content
  ///           space. Both zero means "all of it".
  ///   color = tint drawn over the node while the pointer is inside it
  ///   param = tint drawn over it while it is also being pressed
  ///
  /// Both tints are RGBA8 and zero means none, so a node that says nothing
  /// behaves exactly as before. They live on `EndNode` rather than
  /// `BeginNode` because this is where they are *drawn*: an overlay has to go
  /// on top of the subtree, and the subtree ends here.
  ///
  /// Declaring the appearance once and letting the renderer apply it is the
  /// point. Hover is the most frequent state change in any interface and is
  /// pure geometry the renderer already has — recomputing it in the producer
  /// costs a round trip and a whole re-emit per mouse move, to arrive at an
  /// answer the renderer could have had for free.
  ///
  /// The extent lives here and not on `BeginNode` because it is not known
  /// there: how big a node's content turns out to be is a *result* of
  /// emitting its children, not an input to it. The renderer needs it to
  /// clamp scrolling — content minus viewport is exactly how far a node can
  /// travel.
  ///
  /// The emitted span is what makes a *virtualized* node work. A producer
  /// that declares five thousand rows and draws the twelve on screen has told
  /// the renderer two different things: how far this node can eventually
  /// scroll, and how far it can scroll *right now* with what is in the
  /// arena. Without the second the renderer scrolls into memory nobody
  /// filled, which is a blank panel — and a producer that is slow, or
  /// stopped, is exactly when it happens.
  EndNode = 17,
  /// Declares what the enclosing node should be animating *toward*. Ignored
  /// outside a `BeginNode`/`EndNode` pair.
  ///
  ///   color = `SceneAnimationFlags`: which properties this states
  ///   x, y  = target translation, added to the node's local offset
  ///   w     = target opacity, 0…1, multiplied through the subtree
  ///   aux   = time constant in seconds, or a duration if
  ///           `kSceneAnimDuration` is set; 0 uses the renderer's default
  ///
  /// A *target*, not a value, and that is the whole difference. The producer
  /// says where the node should end up and stops thinking about it; the
  /// renderer carries it there at the display rate. A producer that animated
  /// by republishing a new value every frame would have to be scheduled every
  /// frame to do it, which is the thing this exists to avoid — and it would
  /// stop dead the moment that process got busy.
  ///
  /// A property is animated only while it is being declared. Retained like
  /// everything else about a node, so a frame that ran out of arena before
  /// reaching this command leaves the target alone rather than snapping it
  /// back — but a producer that *stops* declaring a property keeps its last
  /// target rather than reverting to a default.
  ///
  /// The first frame a node declares one, the property snaps to the target
  /// instead of animating to it: a node that has only just appeared has no
  /// previous value to have moved from, and fading every new node in from
  /// nothing is not a default anyone asked for. To animate an entrance,
  /// declare the start on one frame and the end on the next.
  NodeAnimate = 18,
  /// Asks the enclosing scroll node to reveal a producer-selected target.
  ///
  ///   x, y  = requested scroll target
  ///   param = request serial; a repeated serial is ignored
  ///
  /// The serial matters because draw lists are republished: without it every
  /// frame would pull a node back to the selection after the user wheeled it.
  NodeScrollTo = 20,
  /// A drop shadow: a rounded rectangle whose edge fades outwards.
  ///
  ///   x, y, w, h = the rect casting it, in this surface's own coordinates
  ///   aux        = corner radius, which must match the window's or the
  ///                shadow will not sit under it
  ///   param      = blur in pixels: how far the fade reaches past the rect
  ///   color      = the shadow's colour and its opacity at full strength
  ///
  /// A shape rather than a post-process, because that is what it is: a
  /// compositor knows the rectangle a window occupies and needs no picture of
  /// the window to draw what falls outside it. Blurring an actual image of the
  /// window would cost a pass over the whole thing every frame to produce
  /// something the SDF already describes exactly.
  Shadow = 19,
};

/// Bits in `NodeAnimate.color` — which properties the command states.
///
/// A bitfield rather than sentinel values because zero is a meaningful
/// target for both: fully transparent, and no displacement.
enum SceneAnimationFlags : uint32_t {
  kSceneAnimOpacity   = 1u << 0,
  kSceneAnimTranslate = 1u << 1,
  /// Read `aux` as a **duration** rather than a time constant: the node
  /// leaves where it is, arrives at the target, and takes exactly that long
  /// doing it.
  ///
  /// The difference is not the feel, it is coordination. An exponential
  /// approach never technically finishes, so two nodes easing with the same
  /// time constant from different distances stop being visibly in motion at
  /// different moments — the near one settles while the far one is still
  /// travelling, and a transition that was meant to read as one movement
  /// reads as several. A duration is the same for both whatever the
  /// distance, so a group started on one frame lands on one frame.
  ///
  /// Costs what it buys: a timed animation has to remember where it started,
  /// so retargeting it mid-flight restarts the clock rather than simply
  /// bending toward the new target the way a decay does.
  kSceneAnimDuration  = 1u << 2,
};

/// Bits in `BeginNode.color`.
enum SceneNodeFlags : uint32_t {
  /// Clip children to the node's viewport. Equivalent to bracketing the
  /// subtree in `PushClip`/`PopClip`, but it moves with the node.
  kSceneNodeClip = 1u << 0,
  /// The renderer owns a vertical scroll offset for this node: wheel events
  /// inside its viewport move it, and the producer is not told and does not
  /// need to be.
  kSceneNodeScrollY = 1u << 1,
  kSceneNodeScrollX = 1u << 2,
  /// Report hover for semantic callbacks even when the node declares no tint.
  kSceneNodeHitTest = 1u << 3,
  /// Descendant commands are already in window coordinates. Apply retained
  /// transforms, but do not add this node's origin to them a second time.
  kSceneNodeAbsoluteCoordinates = 1u << 4,
  /// The producer has its own use for the wheel here — a camera to zoom, a
  /// document to page — so the renderer must not scroll a container on its
  /// behalf just because one happens to enclose this node.
  ///
  /// Without it every wheel-handling widget inside a retained scroll view is
  /// unreachable: the enclosing container is under the pointer too, and it is
  /// the one that scrolls. Declaring the claim is the only way the renderer
  /// can know the difference between "nothing here wants the wheel" and
  /// "something here wants it and this process cannot see what".
  kSceneNodeWheel = 1u << 5,
};

/// One node's scroll offset, on its way back to the producer.
struct SceneNodeOffset {
  uint32_t id = 0;
  float    x = 0.f, y = 0.f;
};

/// One node as it was actually laid out, recorded during the last replay.
///
/// Absolute, not local: this is what input is hit-tested against, and a hit
/// test wants the rect the user is looking at rather than one that has to be
/// re-derived by walking ancestors.
struct SceneNodeRect {
  uint32_t id = 0;
  float    x = 0.f, y = 0.f, w = 0.f, h = 0.f;
  float    contentW = 0.f, contentH = 0.f;
  /// Vertical span of content actually drawn, in content space. Equal to
  /// [0, contentH] for a node that emitted everything.
  float    emittedTop = 0.f, emittedBottom = 0.f;
  /// Overlays for pointer state; zero means the node wants none, which is
  /// also how the renderer knows not to hit-test it.
  uint32_t hoverTint = 0, pressTint = 0;
  uint32_t flags = 0;
};

/// One shaped glyph, positioned in absolute window pixels by Swift. Ships in
/// a side buffer parallel to the command list — the same pattern the string
/// table used, except the renderer no longer has to shape anything.
struct GlyphInstance {
  uint32_t glyphId = 0;
  /// Which registered face this id belongs to. Glyph ids are face-relative,
  /// so shipping the id alone would draw the wrong glyph as soon as a second
  /// face or size exists.
  uint32_t fontId = 0;
  float    x = 0.f;  // pen position (baseline origin), window pixels
  float    y = 0.f;
};

static_assert(sizeof(GlyphInstance) == 16, "GlyphInstance must stay packed");

/// One polygon vertex (window pixels), for a `Mesh` command's fill. Ships in
/// a side buffer parallel to the command list — the same pattern as
/// `GlyphInstance`, since a fixed 32-byte `DrawCommand` cannot hold a
/// variable-length vertex list itself.
struct MeshVertex {
  float x = 0.f;
  float y = 0.f;
};

static_assert(sizeof(MeshVertex) == 8, "MeshVertex must stay packed");

/// One already-projected spatial vertex. x/y are window pixels and z is
/// Vulkan depth in 0...1. Projection stays in the UI scene layer for now;
/// the dedicated GPU pipeline owns depth testing and ordered composition.
struct SpatialVertex {
  float x = 0.f;
  float y = 0.f;
  float z = 0.f;
  float u = 0.f;
  float v = 0.f;
  uint32_t color = 0xffffffffu;
  float textured = 0.f;
};
static_assert(sizeof(SpatialVertex) == 28, "SpatialVertex must stay packed");

struct DrawCommand {
  uint32_t kind = 0;
  float x = 0.f;
  float y = 0.f;
  float w = 0.f;
  float h = 0.f;
  uint32_t color = 0xffffffffu; // RGBA8 little-endian (R in low byte)
  uint32_t param = 0;           // kind-specific (string index, …)
  float aux = 0.f;              // corner radius, etc.
};

static_assert(sizeof(DrawCommand) == 32, "DrawCommand must stay 32 bytes");

/// Raw pointer input for Swift hit-testing (Phase 6 full routing later).
enum class InputEventKind : uint32_t {
  None = 0,
  MouseDown = 1,
  MouseUp = 2,
  MouseMove = 3,
  /// Framebuffer / swapchain size changed. `x`/`y` hold new width/height.
  Resize = 4,
  /// Keyboard. `button` = key (GLFW), `x` = action (1 press/repeat, 0 release),
  /// `y` = mods bitfield (GLFW: shift=1, control=2, alt=4, super=8).
  Key = 5,
  /// A committed character. `button` holds the Unicode scalar. Distinct from
  /// Key because key codes are physical: they say nothing about layout, dead
  /// keys or shift state, so only the char callback knows what was typed.
  Text = 6,
  /// Wheel / trackpad. `x`/`y` are scroll deltas in notches; `button` holds
  /// the modifier bitfield so Ctrl+wheel can mean zoom.
  Scroll = 7,
  /// Window content needs a redraw (expose / un-minimize / compositor damage).
  /// No payload in x/y/button.
  Refresh = 8,
  /// Files dropped on the window. `x`/`y` = cursor position, `button` =
  /// path count. The paths themselves don't fit a fixed-size struct — pull
  /// them via `Engine::pendingDroppedFiles()` while handling this event;
  /// the next drop overwrites them.
  FileDrop = 9,
  /// A scene node moved. `button` = node id, `x`/`y` = its scroll offset.
  ///
  /// The read path for state the renderer owns. Scrolling a node deliberately
  /// does not reach the producer — that is what makes it work while the
  /// producer is stopped — but a producer that never learns where its node
  /// ended up cannot virtualize a list, because it has no idea which rows are
  /// on screen. So the *decision* stays here and the *result* goes back.
  ///
  /// Coalesced per node in the queue: only the latest position carries any
  /// information, and an animating scroll produces one of these per frame.
  /// A producer that does not care can ignore the kind entirely; nothing
  /// here obliges it to redraw.
  NodeScroll = 10,
  /// A node finished the animation its producer declared. `button` = node id.
  ///
  /// The other half of declaring a target. A producer that says "move there"
  /// and stops thinking about it has, by construction, no idea when it
  /// arrived — and sequencing one transition after another is the ordinary
  /// reason to care. Guessing with a timer would mean duplicating the
  /// renderer's clock in a process that may not be scheduled when it matters.
  ///
  /// One per transition, on the frame it lands. Not sent for the snap a node
  /// makes the first time it declares an animation, because nothing moved,
  /// and not sent when a producer restates a target it had already reached.
  NodeAnimationDone = 11,
  /// The node under the pointer changed. `button` = node id, 0 for none.
  ///
  /// The renderer hit-tests to draw the tints, so it already knows; without
  /// this the producer hit-tests the same geometry a second time, from
  /// coordinates, to reach the same answer. Worse than redundant once nodes
  /// move: a node the renderer has scrolled or animated is no longer where
  /// the producer declared it, so the producer's own test is wrong exactly
  /// when it matters.
  ///
  /// A press needs no event of its own. The renderer presses whatever is
  /// hovered, and this is queued before the `MouseDown` that follows it, so
  /// "the node this click is for" is the last one reported.
  ///
  /// Coalesced only against the back of the queue — a run of hover changes
  /// collapses, but one separated by a `MouseDown` does not, because that is
  /// the pairing the ordering above depends on.
  NodeHover = 12,
  /// The pointer left this surface. No payload.
  ///
  /// A surface hears about the pointer only while it is over it, so without
  /// this the last `MouseMove` it received is where the pointer appears to
  /// still be: a hover stays lit after the cursor has gone somewhere else
  /// entirely, and a panel that reveals itself on approach never learns it
  /// should hide again.
  ///
  /// Sent by whoever owns the pointer — a compositor — when the surface it was
  /// over stops being the surface it is over. A windowed app gets it from
  /// GLFW's cursor-leave, which answers the same question for the same reason.
  PointerLeave = 13,
};

struct InputEvent {
  uint32_t kind = 0;
  float x = 0.f;
  float y = 0.f;
  int32_t button = 0;
  /// GLFW modifier bitfield. Only populated for MouseDown/MouseUp — Scroll
  /// already repurposes `button` for this, and Key carries it in `y`.
  int32_t mods = 0;
};

/// One frame's worth of drawing: the command stream plus the payload arrays
/// its commands index into (Text names a glyph range, Mesh a vertex range).
///
/// A **view**, not an owner. The storage belongs to whoever filled it and only
/// has to outlive the `RenderWindow::render` call — which is what lets the
/// producer keep a reusable arena and hand the renderer a prefix of it without
/// copying, and what would let the same struct describe a mapped region of
/// shared memory written by another process.
struct DrawList {
  const DrawCommand   *commands           = nullptr;
  size_t               commandCount       = 0;
  const GlyphInstance *glyphs             = nullptr;
  size_t               glyphCount         = 0;
  const MeshVertex    *meshVertices       = nullptr;
  size_t               meshVertexCount    = 0;
  const SpatialVertex *spatialVertices    = nullptr;
  size_t               spatialVertexCount = 0;
};

} // namespace canvas
