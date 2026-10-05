#pragma once

#include <cstdint>

/// Where a fullscreen client's frames go between its GPU and the glass. On
/// with `LAVA_SCANOUT_PROBE`, free when off — one branch on a cached bool.
///
/// Built for "the camera jumps when I turn it", which has two causes that look
/// alike on screen and have nothing else in common. A steady 45 fps on a fixed
/// 75 Hz output is shown for 2, 2, 1 refreshes — uneven, but every frame moves
/// forward, and nothing here can fix it. A frame that is replaced before it is
/// ever scanned out, or that sits behind a fence for a refresh, is a skip — and
/// that one is either the compositor's fault or the client's, which the counts
/// below tell apart:
///
///   * buffer commits and their gaps — what the client actually delivered;
///   * the wait for an acquire point to *exist* — wlroots holds a commit until
///     then, and a long one is a client that commits ahead of its submit;
///   * frames shown vs. replaced unseen — a commit that never reached a flip;
///   * how many refreshes each frame stayed up, from the present events;
///   * how long after its commit each frame's acquire point signalled;
///   * flips submitted before the client's GPU work had signalled — the CRTC
///     then waits on the fence, and a wait past the vblank costs a refresh.
///
/// Only one surface is followed at a time: whichever last covered an output.
/// Everything here runs on the Wayland event loop, so none of it locks. The
/// surface is an opaque key; nothing here dereferences it.
namespace lava {

class GameProbe {
 public:
  static bool on();

  /// `surface` covers an output this frame (null: nothing does, which is not
  /// a reason to stop following the last one — another screen may be idle).
  /// A different surface starts the counts over.
  static void covering(const void *surface, bool fenced, bool composited);

  static bool watching(const void *surface);

  /// The client sent `wl_surface.commit`. It may be held — for an acquire
  /// point to materialise — before it is applied.
  static void clientCommit(const void *surface, bool attachesBuffer);

  /// The commit took effect.
  static void applied(const void *surface, bool attachesBuffer);

  /// The acquire point of a commit `applied` reported signalled, `us` after
  /// the commit took effect — how far behind its own commit the client's GPU
  /// work actually finished.
  static void gpuSignalled(const void *surface, int64_t us);
  /// A buffer arrived while the previous one's GPU work was still running:
  /// the client pipelines. Not a lost frame — see "replaced unseen" for those.
  static void gpuBehind(const void *surface);

  /// An output committed a frame showing the watched surface's current
  /// buffer. `commitSeq` is the output's, to match the present event.
  static void outputCommit(uint32_t commitSeq, bool scanout, bool gpuDone);

  /// The output's present event. `whenUs` is CLOCK_MONOTONIC.
  static void present(uint32_t commitSeq, bool presented, int64_t whenUs,
                      unsigned vblankSeq, int refreshNs);

  static void forget(const void *surface);

  /// Prints the last two seconds and starts again; decides for itself when.
  static void report();
};

}  // namespace lava
