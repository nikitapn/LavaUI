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

  /// The buffer, for `wlr_scene_buffer_create`. Owned here; the scene takes
  /// its own reference.
  wlr_buffer *buffer() { return &buffer_->base; }

  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }

 private:
  CanvasSurface() = default;

  canvas::Engine engine_;
  DmabufBuffer  *buffer_ = nullptr;
  uint32_t       width_  = 0;
  uint32_t       height_ = 0;
};

}  // namespace lava
