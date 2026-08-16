#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "render/draw_command.hpp"
#include "util/result.hpp"

namespace canvas {
class DmabufImage;
struct DmabufImport;
}

class Application {
  struct Impl;
  std::unique_ptr<Impl> impl_;
public:
  // Sets up Vulkan/rendering. assetsRoot is the directory that contains the
  // `shaders/` folder (Swift passes CanvasResources.engineRoot — the SPM
  // resource bundle). Fonts and app images are not resolved here. Prefer
  // absolute paths; do not rely on process cwd.
  // Offscreen path (readPixels / smoke tests).
  [[nodiscard]] canvas::VoidResult init(const std::string &assetsRoot);

  // Opens a GLFW window and presents via swapchain (no readback on the hot
  // path). Input is delivered through GLFW callbacks into the engine.
  [[nodiscard]] canvas::VoidResult initWithWindow(
    const std::string &assetsRoot, const std::string &title);

  /// Client path: no Vulkan, no window, no GPU of any kind.
  ///
  /// Brings up one `AppWindow` with an arena and an input queue and stops
  /// there — enough to run body → layout → emit for a process whose frames
  /// another process draws. `assetsRoot` is not needed and not taken: nothing
  /// here compiles a shader or loads a texture.
  ///
  /// Text still shapes normally. Shaping is FreeType and HarfBuzz and has
  /// never needed the device — only rasterizing into the glyph atlas does,
  /// and that belongs to whoever renders. See `registerFont`.
  [[nodiscard]] canvas::VoidResult initClient();

  /// Brings up a device able to render into buffers another driver reads —
  /// compositor surfaces. See `canvas::DmabufImage`.
  ///
  /// No window: surfaces come later, one per `openExportedWindow`. `drmFd`
  /// names the GPU the consumer renders on; this one has to be the same, and
  /// it is pinned rather than preferred. `importableModifiers` is what the
  /// consumer said it can read, and an empty list is a request to fail rather
  /// than a request to guess.
  [[nodiscard]] canvas::VoidResult initExported(
    const std::string &assetsRoot, int drmFd,
    const std::vector<uint64_t> &importableModifiers);

  /// Opens one more exported surface on the device. Returns its window id, or
  /// 0. Everything shared — pipelines, glyph atlas, texture cache — is already
  /// paid for; this costs attachments and an image.
  uint32_t openExportedWindow(uint32_t width, uint32_t height);

  /// Resizes an exported surface, keeping its buffer if the new size still
  /// fits. True if anything changed.
  ///
  /// `exportedImage` is what says whether the consumer has a new buffer to be
  /// handed: exported buffers are allocated in steps, so most resizes land
  /// inside the image already there and the pointer does not move. Only when a
  /// window outgrows its buffer is a new one allocated — and only then does
  /// anything have to import a dmabuf again.
  bool resizeExportedWindow(uint32_t windowId, uint32_t width, uint32_t height);

  /// A window's exported buffer, or null. Owned here; the consumer reads its
  /// descriptors and does not take them.
  ///
  /// At least the window's size and usually larger — see
  /// `resizeExportedWindow`. The window's frame occupies its top-left corner,
  /// so a consumer showing the whole image would show slack along two edges.
  const canvas::DmabufImage *exportedImage(uint32_t windowId) const;

  /// Whether the consumer of exported frames waits on their fence rather than
  /// leaving canvas to block until the GPU is done. See
  /// `RenderDevice::setExportFenceHonoured`; a consumer that says yes must
  /// collect `takeFrameFence` after every frame it shows.
  void setExportFenceHonoured(bool honoured);

  /// The sync_file for a window's last exported frame, or -1. The caller owns
  /// the fd. See `RenderWindow::takeFrameFence`.
  int takeFrameFence(uint32_t windowId);

  /// Blocks until this window's submitted frames have finished. What a
  /// consumer that meant to wait on a fence falls back to when it turns out it
  /// cannot.
  void waitForFrames(uint32_t windowId);

  /// See `AppWindow::setClientSize`. No-op on a window that has a renderer.
  void setClientSize(float width, float height, uint32_t windowId = 0);

  /// See `AppWindow::setMinimumSize`. No-op on a client window.
  void setMinimumSize(float width, float height, uint32_t windowId = 0);

  /// See `AppWindow::postInputEvent`.
  void postInputEvent(uint32_t kind, float x, float y, int32_t button,
                      int32_t mods, uint32_t windowId = 0);

  // ─── Windows ─────────────────────────────────────────────────────────────
  //
  // Every call below that concerns one window takes a trailing `windowId`.
  // Zero means "the first window", so single-window callers never mention it.
  // Ids are handed out by openWindow and never reused.

  /// Opens an additional window on the same device — same font atlas, same
  /// texture cache, same GPU. Returns its id, or 0 on failure.
  ///
  /// It starts hidden. Show it with `setWindowVisible` once a frame has been
  /// drawn into it, or the compositor presents an undefined swapchain image.
  uint32_t openWindow(int width, int height, const std::string &title);

  /// Closes one window; the device and every other window survive.
  void closeWindow(uint32_t windowId);

  size_t windowCount() const;
  /// Id of the window at `index` in creation order, or 0 if out of range.
  uint32_t windowIdAt(size_t index) const;

  bool windowShouldClose(uint32_t windowId = 0) const;
  void requestClose(uint32_t windowId = 0);

  /// See `AppWindow::takeInternalRepaint`.
  bool takeInternalRepaint(uint32_t windowId = 0);

  /// See `AppWindow::scrollSceneUnclaimed`.
  bool scrollSceneUnclaimed(float dx, float dy, uint32_t windowId = 0);

  /// Place the GLFW window over a layout slot (screen coordinates, pixels).
  /// Size changes rebuild the Vulkan framebuffer on the next ensure/repaint.
  void setWindowFrame(int x, int y, int width, int height, uint32_t windowId = 0);

  /// Show or hide the GLFW window (does not destroy it).
  void setWindowVisible(bool visible, uint32_t windowId = 0);

  /// Rounds a window's corners. `radius` 0 turns it off; `top`/`bottom` pick
  /// which pair, so a title bar and the content under it can each round the
  /// two they own and meet flush. See `RenderWindow::setCornerRadius`.
  void setWindowCornerRadius(float radius, bool top, bool bottom,
                             uint32_t windowId = 0);

  /// The pointer image over a window. See `AppWindow::setCursorShape`.
  void setCursorShape(uint32_t shape, uint32_t windowId = 0);

  /// True while minimized. A live GLFW query, not a cached flag — WM
  /// minimize/restore doesn't route through `setWindowVisible`, so caching
  /// would need its own callback wiring to stay correct.
  bool isIconified(uint32_t windowId = 0) const;

  /// X11 Window id for AppMenu Registrar, or 0 if not X11 / no window.
  uint32_t x11WindowId(uint32_t windowId = 0) const;

  // Renders the current retained scene. Offscreen: to the readback target.
  // Windowed: blit to swapchain and present. Returns false on error.
  //
  // Outside a frame group this also runs `prepareFrames`/`retireFrames`
  // around the draw, so a caller that renders one window at a time — which is
  // every windowed app — needs to know none of this.
  bool repaint(uint32_t windowId = 0);

  /// Takes the next frame a producer has published into this window's arena,
  /// without drawing it. See `AppWindow::pollDrawArena`.
  bool pollDrawArena(uint32_t windowId = 0);

  /// Frames this window has actually drawn, or 0 if it has no renderer.
  ///
  /// Monotonic, and it does not advance on a `repaint` that had nothing to
  /// draw — a window fed by an arena whose producer has published nothing
  /// since the last call returns success without rendering. That distinction
  /// is the whole reason to expose this: a consumer downstream of the frame
  /// needs to know whether there is anything new to show, and "repaint
  /// succeeded" does not say.
  uint64_t frameCounter(uint32_t windowId = 0) const;

  /// The part of this window's last frame that is fully opaque, already
  /// narrowed by the window's rounding. False when the producer claimed
  /// nothing, which is the default and always safe.
  /// See `RenderWindow::opaqueBounds`.
  bool opaqueBounds(uint32_t windowId, float &x, float &y, float &w,
                    float &h) const;

  /// Brackets a set of `repaint` calls that may run concurrently, one thread
  /// per window.
  ///
  /// Some of what a frame needs is not the window's but the device's: picking
  /// up a resize, growing the shared glyph atlas, freeing images no window
  /// still references. Each of those reaches across every window — reading
  /// their fences, rewriting their descriptor sets, idling the device — and
  /// none of it is safe while a window is recording. With one thread that
  /// distinction did not exist and the work sat inside `repaint`. With a
  /// worker per window it has to happen either side of them instead.
  ///
  /// ```cpp
  /// app.beginFrameGroup();
  /// // ... repaint(id) on N threads ...
  /// app.endFrameGroup();
  /// ```
  ///
  /// Both are main-thread calls, and neither may run while a repaint is in
  /// flight — that is the contract the group exists to state.
  void beginFrameGroup();
  void endFrameGroup();

  /// The two halves of a frame group, also run around a solo `repaint`.
  void prepareFrames();
  void retireFrames();

  /// Drives this window from a shared-memory draw arena another process
  /// writes, instead of from a draw list submitted in-process.
  bool attachDrawArena(const std::string &id, uint32_t windowId = 0);
  void detachDrawArena(uint32_t windowId = 0);

  /// Legacy copied submission path. New Swift code writes directly into the
  /// reusable buffers below and commits only the used element counts.
  void submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const canvas::GlyphInstance *glyphs, size_t glyphCount,
                      const canvas::MeshVertex *meshVerts, size_t meshVertCount,
                      const canvas::SpatialVertex *spatialVerts, size_t spatialVertCount,
                      uint32_t windowId = 0);
  void ensureDrawListCapacity(size_t cmdCapacity, size_t glyphCapacity,
                              size_t meshVertCapacity, size_t spatialVertCapacity,
                              size_t gradientCapacity, uint32_t windowId = 0);
  canvas::DrawCommand *drawCommandData(uint32_t windowId = 0);
  canvas::GlyphInstance *drawGlyphData(uint32_t windowId = 0);
  canvas::MeshVertex *drawMeshVertexData(uint32_t windowId = 0);
  canvas::SpatialVertex *drawSpatialVertexData(uint32_t windowId = 0);
  canvas::GradientDesc *drawGradientData(uint32_t windowId = 0);
  size_t drawCommandCapacity(uint32_t windowId = 0) const;
  size_t drawGlyphCapacity(uint32_t windowId = 0) const;
  size_t drawMeshVertexCapacity(uint32_t windowId = 0) const;
  size_t drawSpatialVertexCapacity(uint32_t windowId = 0) const;
  size_t drawGradientCapacity(uint32_t windowId = 0) const;
  void commitDrawList(size_t cmdCount, size_t glyphCount,
                      size_t meshVertCount, size_t spatialVertCount,
                      size_t gradientCount, uint32_t windowId = 0);
  bool pollInputEvent(canvas::InputEvent &out, uint32_t windowId = 0);

  /// Paths from the most recent FileDrop event, pulled by index — see the
  /// note on `canvas::InputEventKind::FileDrop`. Valid until the next drop.
  int pendingDroppedFileCount(uint32_t windowId = 0);
  std::string pendingDroppedFile(int index, uint32_t windowId = 0);

  /// Current swapchain / framebuffer size in pixels (after last ensure).
  void framebufferSize(float &outW, float &outH, uint32_t windowId = 0) const;

  /// Whole-window camera: layout stays in window pixels; renderer zooms/pans.
  /// `zoom` must be > 0 (clamped to 1 if not). Pan is in layout pixels.
  void setViewTransform(float zoom, float panX, float panY, uint32_t windowId = 0);

  /// Load the face TextRenderer uses for draw-list text. Swift is the only
  /// caller (FontStore); Application does not pick a default path.
  [[nodiscard]] canvas::VoidResult loadFont(const std::string &path, float pixelSize);
  int registerFont(const std::string &path, uint32_t pixelSize26_6,
                   uint32_t faceIndex, uint32_t rasterFlags);

  /// System clipboard (GLFW-backed; empty when headless).
  std::string clipboardText() const;
  void setClipboardText(const std::string &text);

  /// Load a PNG/JPEG (stb) for draw-list `Image` commands. Returns texture id
  /// (>0) or -1. Idempotent per absolute path (refcounted in TextureManager).
  int loadTexture(const std::string &path);
  /// Drops one reference; frees only once no in-flight frame can name it.
  void unloadTexture(const std::string &path);
  /// Uploads pre-decoded RGBA8. Must run on the thread owning the device.
  int uploadTexture(const std::string &key, const uint8_t *rgba,
                    uint32_t width, uint32_t height);
  /// GPU crop of a dma-buf. Texture id (>0), or -1. See
  /// `TextureManager::importDmabufTexture`.
  int importDmabufTexture(const std::string &key,
                          const canvas::DmabufImport &src, int32_t x,
                          int32_t y, uint32_t w, uint32_t h);
  bool hasTexture(const std::string &key) const;
  /// Takes a reference on an already-resident `key` and reports its size.
  /// Returns the texture id, or -1 if the key is not resident — in which case
  /// the caller still has to decode. See `TextureManager::reviveTexture`.
  int reviveTexture(const std::string &key, uint32_t &outWidth,
                    uint32_t &outHeight);
  /// Pixel size of a loaded texture; returns false if id unknown.
  bool textureSize(uint32_t textureId, float &outW, float &outH) const;

  // ─── Input bridge (canvas-local coords, GLFW-style key codes) ───────────

  void pointerMove(float x, float y, uint32_t windowId = 0);
  void pointerButton(int button, bool pressed, float x, float y, uint32_t windowId = 0);
  void keyEvent(int key, int action, int mods, uint32_t windowId = 0);
  void textInput(const std::string &utf8, uint32_t windowId = 0);
  /// Synthetic wheel/trackpad delta; same coalescing queue as hardware scroll.
  void scroll(float dx, float dy, uint32_t windowId = 0);

  // Copies the frame repaint() just rendered (RGBA8) into dst. dst must be
  // at least width*height*4 bytes.
  void readPixels(uint8_t *dst, size_t dstSize, uint32_t windowId = 0);

  /// GPU→CPU capture of the resolve target (works windowed). See RenderDevice::captureFrame.
  void captureFrame(uint8_t *dst, size_t dstSize, uint32_t windowId = 0);

  /// Capture resolve as PNG (optional crop + optional max-side downsample).
  /// `w`/`h` <= 0 → full frame. `maxSide` ≤ 0 → no downsample.
  bool capturePng(std::vector<uint8_t> &outPng, int x, int y, int w, int h,
                  int maxSide = 0, int *outW = nullptr, int *outH = nullptr,
                  uint32_t windowId = 0);

  /// Same as capturePng, base64-encoded (empty string on failure).
  std::string capturePngBase64(int x, int y, int w, int h, int maxSide = 0,
                               int *outW = nullptr, int *outH = nullptr,
                               uint32_t windowId = 0);

  void shutdown();

  Application(int width = 1280, int height = 720);
  ~Application();
};
