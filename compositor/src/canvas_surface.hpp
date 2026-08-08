#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "bridge/canvas_engine.hpp"

#include "wlr.hpp"

/// Canvas drawing the surfaces the compositor shows.
///
/// This is the join the whole project points at. LavaUI clients have no GPU:
/// they publish a draw list and something else draws it. That something else
/// is canvas, which is Vulkan; the scene graph showing the result is wlroots,
/// which is not. Neither can see the other's images — but both speak dmabuf,
/// so canvas renders into buffers wlroots imports and nothing is copied.
///
/// Split in two, because a compositor has one GPU and as many surfaces as it
/// has clients:
///
///   * `CanvasRenderer` owns the device. One per compositor. The glyph atlas,
///     the texture cache, the pipelines and the font ids all live here, and
///     they are shared by every surface — which is the point, and is what
///     stops a second client from costing a second Vulkan device.
///   * `CanvasSurface` is one client's window: its own attachments, its own
///     exported image, its own arena. That is what a surface should cost.
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

class CanvasSurface;

class CanvasRenderer {
 public:
  /// Brings canvas up on the GPU `renderer` uses. Null, having said why, if
  /// any of the agreements a shared buffer needs cannot be reached.
  static std::unique_ptr<CanvasRenderer> create(wlr_renderer *renderer);

  ~CanvasRenderer();

  CanvasRenderer(const CanvasRenderer &)            = delete;
  CanvasRenderer &operator=(const CanvasRenderer &) = delete;

  /// Opens a surface. Null if the device could not export one that size.
  std::unique_ptr<CanvasSurface> createSurface(uint32_t width,
                                               uint32_t height);

  /// Loads a face into the shared glyph atlas and returns the id a client's
  /// `GlyphInstance`s must carry, or -1.
  ///
  /// Device-wide, not per surface: one atlas serves every window, so a face
  /// registered for one client is already rasterised for the next.
  int registerFont(const std::string &path, float pixelSize);

  canvas::Engine &engine() { return engine_; }

 private:
  CanvasRenderer() = default;

  canvas::Engine engine_;
};

/// One client's window.
class CanvasSurface {
 public:
  CanvasSurface(CanvasRenderer &renderer, uint32_t windowId,
                DmabufBuffer *buffer, uint32_t width, uint32_t height);
  ~CanvasSurface();

  CanvasSurface(const CanvasSurface &)            = delete;
  CanvasSurface &operator=(const CanvasSurface &) = delete;

  /// Renders whatever another process publishes into the arena named `id`.
  ///
  /// The arena is shared memory the client writes its draw list straight
  /// into, so a frame crosses the process boundary without being copied or
  /// serialised. False simply means no arena by that name exists — normal
  /// before a client has made one — so this is quiet on failure.
  bool attachArena(const std::string &id);

  /// Draws whatever the arena currently holds.
  ///
  /// True only when a *new* frame was drawn. A producer that has published
  /// nothing since the last call is not an error and not a frame: the previous
  /// contents are still correct and still on screen.
  bool renderFromArena();

  /// Hands a wheel notch back to the scene after the client's own tree
  /// declined it. See `ScrollUnclaimed` in the IDL.
  void scrollUnclaimed(float dx, float dy);

  /// PNG of the last frame, or a region of it. `w`/`h` <= 0 means the whole
  /// surface; `maxSide` > 0 downsamples so the longer encoded edge fits.
  bool capturePng(int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide,
                  std::vector<uint8_t> &outPng, uint32_t &outW, uint32_t &outH);

  /// The buffer, for `wlr_scene_buffer_create`. Owned here; the scene takes
  /// its own reference.
  wlr_buffer *buffer() { return &buffer_->base; }

  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }

 private:
  /// Writes the resolve target to `$LAVA_CANVAS_DUMP` if it is set.
  void dumpIfRequested();

  CanvasRenderer &renderer_;
  uint32_t        windowId_ = 0;
  DmabufBuffer   *buffer_   = nullptr;
  uint32_t        width_    = 0;
  uint32_t        height_   = 0;
  /// Frames drawn as of the last `renderFromArena`, so a poll that found
  /// nothing published can be told from one that drew.
  uint64_t drawn_ = 0;
};

}  // namespace lava
