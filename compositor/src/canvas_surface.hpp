#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include "bridge/canvas_engine.hpp"

#include "wlr.hpp"

/// Canvas drawing a surface the compositor shows.
///
/// This is the join the whole project points at. LavaUI clients have no GPU:
/// they publish a draw list and something else draws it. That something else
/// is canvas, which is Vulkan; the scene graph showing the result is wlroots,
/// which is not. Neither can see the other's images — but both speak dmabuf,
/// so canvas renders into a buffer wlroots imports and nothing is copied.
///
/// Everything hard about that lives in `canvas::DmabufImage`, on the canvas
/// side, where the Vulkan device is. What is left here is the half that is
/// genuinely about wlroots: asking the compositor's renderer what it can
/// import, and dressing the result up as a `wlr_buffer`.
namespace lava {

/// A `canvas::DmabufImage` presented to wlroots as a buffer.
///
/// `wlr_buffer` is an interface, not a class: wlroots calls back for the
/// dmabuf attributes when a renderer needs to import it. Deriving lets the
/// callbacks recover this object from the `wlr_buffer *` they are handed,
/// since the base is the first member.
struct DmabufBuffer {
  wlr_buffer base{};
  const canvas::DmabufImage *image = nullptr;

  /// The returned buffer is owned by the caller; drop it with
  /// `wlr_buffer_drop`. It does not take ownership of `image`.
  static DmabufBuffer *create(const canvas::DmabufImage *image);
};

class CanvasSurface {
 public:
  /// Brings up canvas on the GPU `renderer` uses and allocates a shared
  /// buffer of `width` x `height`. Null, having said why, if any of the
  /// agreements that make a shared buffer possible cannot be reached.
  static std::unique_ptr<CanvasSurface> create(wlr_renderer *renderer,
                                               uint32_t width, uint32_t height);

  ~CanvasSurface();

  CanvasSurface(const CanvasSurface &)            = delete;
  CanvasSurface &operator=(const CanvasSurface &) = delete;

  /// Draws `commands` into the shared buffer and hands it over.
  bool render(const std::vector<canvas::DrawCommand> &commands);

  /// Renders whatever another process has published into the arena named
  /// `id`, instead of commands written here.
  ///
  /// The arena is shared memory the client writes its draw list straight
  /// into, so a frame crosses the process boundary without being copied or
  /// serialised. The client owns no GPU and no window; this owns both and
  /// knows nothing about the view tree that produced the commands.
  ///
  /// False simply means no arena by that name exists yet, which is the normal
  /// state before a client starts. Quiet on failure for that reason — the
  /// caller retries.
  bool attachArena(const std::string &id);

  /// Loads a face into the shared glyph atlas and returns the id the client's
  /// `GlyphInstance`s must carry, or -1.
  ///
  /// Ids are assigned in registration order, which is the whole of the
  /// agreement between the two processes about fonts — see the call site in
  /// `main.cpp` for why that is a stopgap and not a design.
  int registerFont(const std::string &path, float pixelSize);

  /// Draws whatever the arena currently holds.
  ///
  /// True only when a *new* frame was drawn. A producer that has published
  /// nothing since the last call is not an error and not a frame: the
  /// previous contents are still correct and still on screen, and reporting
  /// otherwise would damage the scene sixty times a second to show the same
  /// pixels.
  bool renderFromArena();

  /// The buffer, for `wlr_scene_buffer_create`. Owned here; the scene takes
  /// its own reference.
  wlr_buffer *buffer() { return &buffer_->base; }

  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }

 private:
  CanvasSurface() = default;

  /// Writes the resolve target to `$LAVA_CANVAS_DUMP` if it is set.
  void dumpIfRequested();

  canvas::Engine engine_;
  DmabufBuffer  *buffer_ = nullptr;
  uint32_t       width_  = 0;
  uint32_t       height_ = 0;
  /// Frames drawn as of the last `renderFromArena`, so a tick that found
  /// nothing published can be told from one that drew.
  uint64_t drawn_ = 0;
};

}  // namespace lava
