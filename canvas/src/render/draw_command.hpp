#pragma once

// Authoritative POD draw-list command (C ABI layout). Swift imports this
// struct; do not redefine it on the Swift side.
//
// Fixed 32-byte stride for a simple pointer+count boundary.

#include <cstddef>
#include <cstdint>

#include "gen/drawlist.hpp"

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

using DrawCommandKind = ::lava::draw::DrawCommandKind;

/// In a `Shadow` command's `param`: the bit that makes it hollow. The blur
/// is the low 13 bits; nobody blurs by more than 8191 pixels.
inline constexpr uint32_t kShadowHollow = 0x80000000u;
inline constexpr uint32_t kShadowBlurMask = 0x1fffu;

/// Where a hollow shadow's caster sits relative to the shadow, in whole
/// pixels: x in bits 13–21 and y in bits 22–30, each a 9-bit two's
/// complement (±255). The shadow is the caster moved by an offset, and CSS
/// cuts the hole at the *caster* — cut at the shadow's own rect, a shadow
/// dropped 8px below a translucent bar darkened the bar's top 8px with its
/// own falloff. Zero on everything written before the offset existed.
inline void shadowHoleOffset(uint32_t param, float &dx, float &dy) {
  auto field = [](uint32_t bits) {
    const int32_t v = static_cast<int32_t>(bits & 0x1ffu);
    return static_cast<float>(v >= 256 ? v - 512 : v);
  };
  dx = field(param >> 13);
  dy = field(param >> 22);
}

/// Backdrop saturation, as one byte: what CSS's `saturate()` does to the
/// frost after the blur. 255 is "unchanged" — it is what every producer that
/// predates this sends, the colour of an in-window backdrop blur being white —
/// and anything else is the factor times 64, so up to just under 4. Shared by
/// the in-window blur (`BeginBackdropBlur`'s red byte) and the composite
/// instance (`color1`'s red byte), so the two cannot drift.
inline constexpr uint8_t kSaturationUnchanged = 255;

constexpr uint8_t encodeSaturation(float factor) {
  if (!(factor >= 0.f) || (factor > 0.999f && factor < 1.001f)) {
    return kSaturationUnchanged;
  }
  const float scaled = factor * 64.f + 0.5f;
  return static_cast<uint8_t>(scaled >= 254.f ? 254.f : scaled);
}

constexpr float decodeSaturation(uint8_t byte) {
  return byte == kSaturationUnchanged ? 1.f : static_cast<float>(byte) / 64.f;
}


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

/// Bits in `NodeScrollTo.color`.
enum SceneScrollFlags : uint32_t {
  /// Be there now: set the node's *position* as well as its target, so the
  /// frame carrying this command already draws at the requested offset
  /// instead of easing toward it.
  ///
  /// The ease exists for a request that names a step — a wheel notch, a
  /// reveal — where turning a jump into a movement is the renderer's whole
  /// contribution. A drag names a position instead: the pointer is already
  /// there, and easing toward it leaves the content `velocity x tau` behind
  /// the finger for as long as the finger keeps moving. That is not
  /// smoothing, it is lag, and it is the one input the ease must not touch.
  ///
  /// The producer has to have drawn the destination in this same frame — the
  /// span in this node's `EndNode` must contain it. Nothing verifies that
  /// here, because the check cannot run yet: `EndNode` arrives later in the
  /// same list. A producer that asks to be somewhere it did not draw gets
  /// blank pixels until its next frame, and the step after that pulls it
  /// back to the edge of what was drawn.
  kSceneScrollImmediate = 1u << 0,
};

using SceneNodeFlags = ::lava::draw::SceneNodeFlag;

inline constexpr uint32_t kSceneNodeClip =
    static_cast<uint32_t>(SceneNodeFlags::clip);
inline constexpr uint32_t kSceneNodeScrollY =
    static_cast<uint32_t>(SceneNodeFlags::scrollY);
inline constexpr uint32_t kSceneNodeScrollX =
    static_cast<uint32_t>(SceneNodeFlags::scrollX);
inline constexpr uint32_t kSceneNodeHitTest =
    static_cast<uint32_t>(SceneNodeFlags::hitTest);
inline constexpr uint32_t kSceneNodeAbsoluteCoordinates =
    static_cast<uint32_t>(SceneNodeFlags::absoluteCoordinates);
inline constexpr uint32_t kSceneNodeWheel =
    static_cast<uint32_t>(SceneNodeFlags::wheel);
inline constexpr uint32_t kSceneNodeHoverSnap =
    static_cast<uint32_t>(SceneNodeFlags::hoverSnap);

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
  /// Where this node is allowed to be *seen*: the intersection of the
  /// scissors its ancestors pushed, in the same absolute pixels as `x`/`y`.
  ///
  /// Recorded because a node's rect is where it was drawn, not where it is
  /// visible, and hit testing wants the second. A menu row scrolled up out of
  /// its panel keeps a perfectly good rect over whatever is above the panel —
  /// the menu bar, say — and without this the pointer lands on a row nobody
  /// can see instead of the title it is actually over.
  float clipX0 = -1e9f, clipY0 = -1e9f, clipX1 = 1e9f, clipY1 = 1e9f;

  bool visibleAt(float px, float py) const {
    return px >= clipX0 && px < clipX1 && py >= clipY0 && py < clipY1;
  }
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
/// Vulkan depth in 0...1. `w` is the camera-space Z the producer divided
/// by — the vertex shader puts it in clip w so UVs interpolate in the
/// plane, not in screen space. A 64° album card without that looks like
/// the cover was squeezed onto the near edge (affine mapping).
/// Projection stays in the UI scene layer; the GPU pipeline owns depth
/// testing and ordered composition.
struct SpatialVertex {
  float x = 0.f;
  float y = 0.f;
  float z = 0.f;
  float u = 0.f;
  float v = 0.f;
  uint32_t color = 0xffffffffu;
  float textured = 0.f;
  float w = 1.f;
};
static_assert(sizeof(SpatialVertex) == 32, "SpatialVertex must stay packed");

/// The parameters of one gradient, pointed at by `LinearGradientRect.param`.
///
/// Deliberately roomier than a two-stop ramp needs. `flags` is reserved so a
/// later multi-stop or radial gradient can be added without moving anything:
/// it would name a gradient type and a range in a stops array, and the two
/// colours here stay meaningful as the ends. Sixteen bytes now costs nothing —
/// there is one of these per gradient, not per quad — and keeps that door open.
struct GradientDesc {
  /// Where the ramp starts. `DrawCommand.color` carries the same value, so a
  /// consumer that does not implement gradients still paints something sane.
  uint32_t color0 = 0xffffffffu;
  uint32_t color1 = 0xffffffffu;
  /// Radians, from +x towards +y: 0 is left-to-right, π/2 top-to-bottom. The
  /// ramp always spans the rect exactly, whatever the angle or aspect ratio.
  float angle = 0.f;
  /// Reserved; must be zero. See above.
  uint32_t flags = 0;
};

static_assert(sizeof(GradientDesc) == 16, "GradientDesc must stay packed");

struct DrawCommand {
  uint32_t kind = static_cast<uint32_t>(DrawCommandKind::rect);
  float x = 0.f;
  float y = 0.f;
  float w = 0.f;
  float h = 0.f;
  uint32_t color = 0xffffffffu; // RGBA8 little-endian (R in low byte)
  uint32_t param = 0;           // kind-specific (string index, …)
  float aux = 0.f;              // corner radius, etc.
};

static_assert(sizeof(DrawCommand) == 32, "DrawCommand must stay 32 bytes");

using InputEventKind = ::lava::draw::InputEventKind;

struct InputEvent {
  uint32_t kind = static_cast<uint32_t>(InputEventKind::none);
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
  const GradientDesc  *gradients          = nullptr;
  size_t               gradientCount      = 0;
};

} // namespace canvas
