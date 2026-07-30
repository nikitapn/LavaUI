#pragma once

// Authoritative POD draw-list command (C ABI layout). Swift imports this
// struct; do not redefine it on the Swift side.
//
// Fixed 32-byte stride for a simple pointer+count boundary.

#include <cstdint>

namespace canvas {

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
  BeginBackdropBlur = 8,
  /// Closes a blur scope (bookkeeping / future nesting). No GPU work yet.
  EndBackdropBlur = 9,
  /// Content blur. Everything between Begin and End is drawn into an offscreen
  /// target instead of the frame, blurred, and composited back over the rect in
  /// x,y,w,h with its own alpha. `aux` = radius in pixels. Where backdrop blur
  /// frosts what is *behind* a view, this softens the view itself.
  BeginContentBlur = 10,
  EndContentBlur = 11,
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
};

struct InputEvent {
  uint32_t kind = 0;
  float x = 0.f;
  float y = 0.f;
  int32_t button = 0;
};

} // namespace canvas
