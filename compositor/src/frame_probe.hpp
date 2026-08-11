#pragma once

#include <cstdint>

/// Where a frame's time goes, per surface. Off unless `LAVA_FRAME_PROBE` is
/// set, and free when it is off — one branch on a cached bool.
///
/// Built for the question "why does scrolling stutter", which averages answer
/// badly: sixty frames at 1 ms and one at 40 is a smooth number and a visible
/// hitch. So every stage reports its **worst** frame alongside its mean, and
/// the gap between frames is measured as well as their cost — a stutter is
/// either a frame that took too long or a frame that never came, and those
/// have different causes and different fixes.
///
/// What the stages mean, in the order a frame passes through them:
///
///   * `Arena`  — taking the draw list the client published. Client-side cost
///                shows up here as *absence*: a long gap with a short arena.
///   * `Render` — recording and submitting the frame to the GPU. Whether this
///                includes waiting for the GPU depends on the handover mode
///                logged at startup; see `RenderDevice::setExportFenceHonoured`.
///   * `Scene`  — handing the buffer to wlroots.
///   * `Redraw` — a frame the *compositor* decided to draw, not the client:
///                hover, scroll, an animation step. Two of these per notch
///                where you expected one is the shape of a scroll problem.
///
/// Everything here is called from the Wayland event loop and nowhere else,
/// which is why none of it locks.
namespace lava {

class FrameProbe {
 public:
  enum class Stage : uint8_t { Arena, Render, Scene, Redraw, Count };

  /// Whether the probe is on. Read this before timing anything — the point of
  /// the probe is to find microseconds, not to spend them.
  static bool on();

  /// Microseconds now, for a caller about to bracket something.
  static int64_t now();

  static void record(uint32_t surfaceId, Stage stage, int64_t startedAt);

  /// One frame reached the screen for this surface. Also what measures the
  /// gap since the last one.
  static void frame(uint32_t surfaceId);

  /// One input event was sent to this surface's client.
  static void input(uint32_t surfaceId);

  /// A surface went away; stop reporting it.
  static void forget(uint32_t surfaceId);

  /// Prints every surface's last two seconds and starts again. Cheap to call
  /// often — it decides for itself when the interval is up.
  static void report();
};

}  // namespace lava
