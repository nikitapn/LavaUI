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

  /// Rounds this surface's corners, in pixels; 0 is square.
  ///
  /// `top`/`bottom` are which pair to round, because a decorated window is two
  /// surfaces: the bar rounds the top two, the content rounds the bottom two,
  /// and the seam between them stays straight. A frameless window is one
  /// surface and rounds all four.
  void setCornerRadius(float radius, bool top, bool bottom);

  /// Resizes the surface and tells its client to lay out again.
  ///
  /// The buffer changes — a dmabuf's size and stride are fixed when it is
  /// allocated, so a new size is a new buffer — which is why the caller has to
  /// hand `buffer()` to the scene again afterwards. False if nothing changed.
  bool resize(uint32_t width, uint32_t height);

  /// Draws a list built here rather than one published by a client.
  ///
  /// What the compositor's own surfaces use — a title bar has no client and no
  /// arena, and its commands come from `Decoration`.
  bool renderList(const std::vector<canvas::DrawCommand> &commands,
                  const std::vector<canvas::GlyphInstance> &glyphs);

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
