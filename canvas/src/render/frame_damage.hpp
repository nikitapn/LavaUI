#pragma once

// Which part of a window changed between two frames, from what was submitted.
//
// A LavaUI window is redrawn whole every frame, and that stays true: the
// client has no idea what changed, and with MSAA the renderer could not keep
// last frame's samples to draw over anyway. What *can* be narrowed is what the
// compositor does with the result. Handing wlroots the whole buffer as damage
// makes it recomposite the window's entire rectangle on the output — for a
// caret blink, a spinner, a clock — and that composite is the part a compositor
// on a battery pays for.
//
// So the renderer keeps a hash per tile of everything it submitted that
// touches that tile, in submission order, and compares against the previous
// frame. Pixels are a pure function of those submissions as long as what they
// sample did not change underneath them, which is what `markAll` is for: a
// frame that blurs (the blur reads beyond any one quad), samples another
// surface's live buffer, or draws depth-tested 3D says so, and the whole frame
// is damaged.
//
// A wrong answer here is stale pixels on screen, so every doubt resolves to
// "everything": a size change, the first frame, a frame nobody compared.
// `LAVA_FULL_DAMAGE=1` turns the whole thing off for an A/B.

#include <cstdint>
#include <vector>

namespace canvas {

/// A damaged rectangle in window pixels.
struct DamageRect {
  int32_t x = 0, y = 0, width = 0, height = 0;
};

class FrameDamage {
 public:
  /// Tile edge in pixels. Small enough that a caret is one column of tiles,
  /// large enough that a full-window fill is a couple of thousand folds.
  static constexpr int kTile = 32;

  /// Starts this frame's tally at `width`×`height` window pixels.
  void begin(uint32_t width, uint32_t height);

  /// Folds `hash` into every tile the rectangle `[x0,x1)×[y0,y1)` touches.
  /// Coordinates are window pixels and are clamped; the caller grows them by
  /// whatever its antialiasing can reach past the geometry.
  void add(float x0, float y0, float x1, float y1, uint64_t hash);

  /// This frame cannot be compared: damage all of it.
  void markAll() { frameAll_ = true; }

  /// Compares with the previous frame and adds what differs to the pending
  /// damage, which accumulates until `take`.
  void end();

  /// Hands over everything damaged since the last call, and forgets it.
  ///
  /// False means "the whole window" and leaves `out` empty. True with an empty
  /// `out` means nothing changed. Rectangles do not overlap.
  bool take(std::vector<DamageRect> &out);

  /// Forgets the previous frame, so the next one is damaged whole. For a
  /// change the hashes cannot see — the destination buffer was swapped.
  void invalidate() {
    havePrevious_ = false;
    pendingAll_ = true;
  }

  /// Order-sensitive hash helpers, exposed so producers mix the same way.
  static uint64_t mix(uint64_t h, uint64_t v);
  static uint64_t hashBytes(const void *data, size_t size, uint64_t seed);

 private:
  uint32_t width_ = 0, height_ = 0;
  uint32_t cols_ = 0, rows_ = 0;
  std::vector<uint64_t> current_;
  std::vector<uint64_t> previous_;
  uint32_t previousCols_ = 0, previousRows_ = 0;
  std::vector<uint8_t> pending_;
  bool havePrevious_ = false;
  bool frameAll_ = false;
  /// Nothing has been taken yet, so the first frame is reported whole.
  bool pendingAll_ = true;
};

} // namespace canvas
