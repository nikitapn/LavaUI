#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "bridge/canvas_engine.hpp"
#include "render/font_key.hpp"

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
  int registerFont(const std::string &path, uint32_t pixelSize26_6,
                   uint32_t faceIndex, uint32_t rasterFlags);

  /// Decodes a file and uploads it as `key`. Texture id (>0), or -1 if the
  /// file will not decode. `outWidth`/`outHeight` are the *decoded* size,
  /// which `maxPixelSize` changes — a client lays out against them, so the
  /// file's own dimensions would be the wrong answer.
  ///
  /// Device-wide for the same reason fonts are: two clients naming the same
  /// asset share one texture, and neither had to send it.
  int registerImage(const std::string &key, const std::string &path,
                    uint32_t maxPixelSize, uint32_t &outWidth,
                    uint32_t &outHeight);

  /// The same, from encoded bytes that never had a file to be opened from.
  int registerImageData(const std::string &key, const uint8_t *bytes,
                        size_t byteCount, uint32_t maxPixelSize,
                        uint32_t &outWidth, uint32_t &outHeight);

  /// Drops the device's reference to `key`. The memory goes back only once
  /// every in-flight frame that could still name it has retired.
  void releaseImage(const std::string &key);

  /// How a draw list names another surface as a texture. `fn` is called
  /// from replay with a compositor surface id; 0 means drop the command.
  using SurfaceTextureResolver = int (*)(void *ctx, uint32_t surfaceId,
                                         uint32_t maxSide);
  void setSurfaceTextureResolver(void *ctx, SurfaceTextureResolver fn);

  /// Import `buffer` as a sampled texture under `key`, optionally
  /// downsampling so the longer edge is `maxSide`. Texture id (>0), or 0
  /// if the buffer has no dma-buf or the import failed.
  int importBufferTexture(wlr_buffer *buffer, const std::string &key,
                          uint32_t maxSide);

  canvas::Engine &engine() { return engine_; }

  /// The GPU everything here is on, for the timelines surfaces synchronise
  /// through. -1 when this renderer never came up.
  int drmFd() const { return drmFd_; }

  /// Whether frames are handed over with a fence instead of a stall. False
  /// when the compositor's own renderer cannot wait on one, in which case
  /// canvas keeps blocking until each frame is finished — see
  /// `RenderDevice::setExportFenceHonoured`.
  bool fencedHandover() const { return fencedHandover_; }

 private:
  CanvasRenderer() = default;

  canvas::Engine engine_;
  int drmFd_ = -1;
  bool fencedHandover_ = false;
};

/// One client's window.
class CanvasSurface {
 public:
  CanvasSurface(CanvasRenderer &renderer, uint32_t windowId,
                DmabufBuffer *buffer, uint32_t width, uint32_t height);
  ~CanvasSurface();

  CanvasSurface(const CanvasSurface &)            = delete;
  CanvasSurface &operator=(const CanvasSurface &) = delete;

  /// The number this surface answers to in the frame probe.
  ///
  /// Two counters run here and they drift apart: the canvas window id counts
  /// every window the engine opened — shadows and title bars included — while
  /// a client surface id counts only the windows a client asked for. Left
  /// alone, a surface files half its report under one number and half under
  /// the other, and the half nobody can look up is the half with the render
  /// cost in it. So the owner names the surface once, here.
  void setReportedId(uint32_t id) { reportedId_ = id; }
  uint32_t reportedId() const { return reportedId_ != 0 ? reportedId_ : windowId_; }

  /// Rounds this surface's corners, in pixels; 0 is square.
  ///
  /// `top`/`bottom` are which pair to round, because a decorated window is two
  /// surfaces: the bar rounds the top two, the content rounds the bottom two,
  /// and the seam between them stays straight. A frameless window is one
  /// surface and rounds all four.
  void setCornerRadius(float radius, bool top, bool bottom);

  /// Resizes the surface and tells its client to lay out again.
  ///
  /// The caller has to hand `buffer()` to the scene again afterwards and to
  /// re-crop the node to the new size. Usually it is the same buffer: exported
  /// images are allocated in steps, so a window that has not outgrown its own
  /// buffer keeps it — see `Application::resizeExportedWindow`. False if
  /// nothing changed.
  bool resize(uint32_t width, uint32_t height);

  /// Draws a list built here rather than one published by a client.
  ///
  /// What the compositor's own surfaces use — a title bar has no client and no
  /// arena, and its commands come from `Decoration`.
  bool renderList(const std::vector<canvas::DrawCommand> &commands,
                  const std::vector<canvas::GlyphInstance> &glyphs);

  /// CPU fallback: uploads `rgba` (`srcW`×`srcH`) as a texture, draws it
  /// across this surface, and runs the content-blur pass at `radius`.
  /// Prefer `frostFromDmabuf` when the capture is a dma-buf.
  ///
  /// `key` names the upload so a later call can drop the previous one.
  /// `cornerRadius` cuts the frost to the window's outline; 0 is square.
  bool frostFromRgba(const uint8_t *rgba, uint32_t srcW, uint32_t srcH,
                     float radius, const std::string &key,
                     float cornerRadius = 0.f);

  /// Same frost, but the pixels stay on the GPU: `src` is the wlroots
  /// capture's dma-buf, cropped to `srcX,srcY,srcW,srcH`. False if the
  /// import or blit failed — the caller can still do the CPU path.
  bool frostFromDmabuf(const wlr_dmabuf_attributes &src, int srcX, int srcY,
                       int srcW, int srcH, float radius,
                       const std::string &key, float cornerRadius = 0.f);

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

  // ─── Input ───────────────────────────────────────────────────────────────
  //
  // Events go *into* the renderer before they go on to the client, and that
  // ordering is the whole point rather than an implementation detail.
  //
  // Part of what an event means is answered here and nowhere else. The
  // renderer holds the retained scene — which node is under the pointer, which
  // is pressed, how far each scrollable one has been dragged — so it can draw
  // a hover highlight, take a wheel notch, or move a subtree without asking
  // the client anything. That is what lets a stopped client's list still
  // scroll, and what makes a hover cost no round trip.
  //
  // Feeding the raw event straight to the client would skip all of it: the
  // client would get the click, and the button under the pointer would never
  // have learned it was hovered. What comes back out of `pollEvent` is the
  // event *plus* whatever the renderer concluded — `NodeHover`, `NodeScroll`,
  // `NodeAnimationDone` — which is what the client should actually receive.
  //
  // Coordinates are surface-local, which is what the caller's hit test already
  // produced.

  void pointerMove(float x, float y);
  void pointerButton(int button, bool pressed, float x, float y, int mods);
  void pointerScroll(float dx, float dy);
  void keyEvent(int key, int action, int mods);
  void textInput(const std::string &utf8);

  /// Takes one event the renderer has for the client, or false if there are
  /// none left. Drain after feeding input in.
  bool pollEvent(canvas::InputEvent &out);

  /// Whether the renderer changed something the client did not ask for — a
  /// hover tint, a scroll offset, an animation step — and the surface needs
  /// drawing again to show it.
  bool takeInternalRepaint();

  /// Redraws the frame already held, without waiting for a new one.
  ///
  /// What `takeInternalRepaint` is answered with: the content has not changed,
  /// but what the renderer draws over it has.
  bool redraw();

  /// Hands a wheel notch back to the scene after the client's own tree
  /// declined it. See `ScrollUnclaimed` in the IDL.
  void scrollUnclaimed(float dx, float dy);

  /// When the frame this surface is holding will have been written.
  ///
  /// The compositor renders a client's frame and hands the buffer to the
  /// scene, and those used to be the same moment because canvas blocked until
  /// the GPU was done — on the event loop, where it cost every other client
  /// the same milliseconds. Now the frame ends at the submit and this is what
  /// the scene is told to wait for instead: `wlr_scene_buffer`'s wait timeline
  /// takes exactly this pair.
  ///
  /// A null timeline means there is nothing to wait for, because there was no
  /// fence to be had and canvas waited itself.
  struct FrameFence {
    wlr_drm_syncobj_timeline *timeline = nullptr;
    uint64_t point = 0;
  };
  FrameFence frameFence() const { return {fenceTimeline_, fencePoint_}; }

  /// PNG of the last frame, or a region of it. `w`/`h` <= 0 means the whole
  /// surface; `maxSide` > 0 downsamples so the longer encoded edge fits.
  bool capturePng(int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide,
                  std::vector<uint8_t> &outPng, uint32_t &outW, uint32_t &outH);

  /// The buffer, for `wlr_scene_buffer_create`. Owned here; the scene takes
  /// its own reference.
  ///
  /// Bigger than the surface, in general: it is allocated in steps so that a
  /// resize can reuse it, and the frame occupies its top-left `width()` by
  /// `height()` corner. A scene node showing it must be cropped to that — see
  /// `crop_to_surface` in the compositor — or the window trails the slack of
  /// its own buffer along two edges.
  wlr_buffer *buffer() { return &buffer_->base; }

  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }

  /// The part of the last frame that is fully opaque, in surface pixels, or
  /// false if none of it is.
  ///
  /// The client says so per frame and the renderer narrows it for this
  /// surface's rounding; all that is left here is handing it to the scene.
  /// See `DrawCommandKind::OpaqueBounds`.
  bool opaqueBounds(float &x, float &y, float &w, float &h) const;

 private:
  /// Content-blur pass over an already-uploaded texture. Shared by the
  /// CPU and dma-buf frost paths.
  bool frostWithTexture(int id, float radius, float cornerRadius);

  /// Writes the resolve target to `$LAVA_CANVAS_DUMP` if it is set.
  void dumpIfRequested();

  /// Moves the fence for the frame just submitted onto this surface's
  /// timeline. Called after every frame; quiet when there is no fence.
  void captureFence();

  CanvasRenderer &renderer_;
  uint32_t        windowId_ = 0;
  uint32_t        reportedId_ = 0;
  DmabufBuffer   *buffer_   = nullptr;
  uint32_t        width_    = 0;
  uint32_t        height_   = 0;
  /// Frames drawn as of the last `renderFromArena`, so a poll that found
  /// nothing published can be told from one that drew.
  uint64_t drawn_ = 0;
  /// This surface's synchronisation timeline, made on the first frame that has
  /// a fence to put on it, and the point that frame signals. One per surface
  /// because a frame is a surface's, not the desktop's.
  wlr_drm_syncobj_timeline *fenceTimeline_ = nullptr;
  uint64_t fencePoint_ = 0;
};

}  // namespace lava
