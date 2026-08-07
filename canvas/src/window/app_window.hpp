#pragma once

#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "ipc/draw_arena.hpp"
#include "render/draw_command.hpp"

struct GLFWwindow;
class RenderDevice;
class RenderWindow;

/// One application window: a platform window, the renderer that draws into it,
/// the draw-list arena its frames are written into, and its input queue.
///
/// Everything here is per window and nothing is shared, which is the whole
/// point — `Application` holds a list of these against one `RenderDevice`, so
/// a second window costs a surface, a swapchain and an arena rather than a
/// second copy of the GPU, the font atlas or the texture cache.
///
/// The arena is deliberately not a queue. A window has exactly one frame in
/// preparation at a time: the producer asks for capacity, writes straight into
/// engine memory, and commits the prefix it filled. That is what keeps
/// submission copy-free, and it is the same shape a mapped shared-memory
/// region would have if the producer were another process.
///
/// Not thread-safe except for the input queue, which GLFW callbacks and the
/// consuming loop genuinely do touch from different places.
class AppWindow {
 public:
  /// Creates the platform window and its renderer. Throws on failure, so a
  /// half-built window never escapes.
  AppWindow(RenderDevice &device, uint32_t id, int width, int height,
            const std::string &title);

  /// Offscreen: no platform window, no present. Everything else — the arena,
  /// the event queue, `repaint()` — behaves the same, so the headless path is
  /// the windowed path with `glfwWindow() == nullptr` rather than a parallel
  /// branch through the whole class.
  AppWindow(RenderDevice &device, uint32_t id, int width, int height);

  /// Client: no platform window, no renderer, no GPU at all.
  ///
  /// What is left is the arena and the input queue — which is exactly what a
  /// process that lays out and emits a frame for *someone else* to draw
  /// needs, and nothing more. A client owns no scene state either: the
  /// retained tree lives wherever the frame is rendered, so hover, scroll
  /// offsets and node animations are answers that arrive here rather than
  /// questions this window can settle.
  ///
  /// Follows the same rule the offscreen constructor set — one class with
  /// null members, not a parallel hierarchy. `glfwWindow() == nullptr` marks
  /// "no platform window"; `render_ == nullptr` now marks "no GPU", and every
  /// method that needs one says so instead of assuming it.
  AppWindow(uint32_t id, int width, int height);
  ~AppWindow();

  AppWindow(const AppWindow &)            = delete;
  AppWindow &operator=(const AppWindow &) = delete;

  uint32_t id() const { return id_; }
  GLFWwindow *glfwWindow() const { return glfw_; }
  RenderWindow &renderWindow() { return *render_; }

  /// Whether this window has a renderer. False only for a client window,
  /// where every GPU-facing call below is a no-op rather than a crash.
  bool hasRenderer() const { return render_ != nullptr; }

  /// Compiles this window's pipelines. Separate from the constructor for the
  /// same reason `RenderWindow::initRenderers` is.
  void initRenderers();

  /// Picks up a window-manager resize, and tells the producer about it.
  ///
  /// Split out of `repaint()` because it is neither safe nor legal on a render
  /// worker: rebuilding the swapchain idles the whole device, and
  /// `glfwGetFramebufferSize` is a main-thread call. Runs in
  /// `Application::prepareFrames`, before any window starts drawing.
  void prepare();

  /// Draws and presents whatever was last committed to the arena.
  ///
  /// Safe to run concurrently with other windows' `repaint()`; see
  /// `RenderDevice::frameMutex_` for what that rests on.
  bool repaint();

  // ─── Draw-list arena ─────────────────────────────────────────────────────

  void ensureDrawListCapacity(size_t cmdCapacity, size_t glyphCapacity,
                              size_t meshVertCapacity, size_t spatialVertCapacity);
  canvas::DrawCommand   *drawCommandData()       { return drawCmds_.data(); }
  canvas::GlyphInstance *drawGlyphData()         { return drawGlyphs_.data(); }
  canvas::MeshVertex    *drawMeshVertexData()    { return drawMeshVerts_.data(); }
  canvas::SpatialVertex *drawSpatialVertexData() { return drawSpatialVerts_.data(); }
  size_t drawCommandCapacity() const      { return drawCmds_.size(); }
  size_t drawGlyphCapacity() const        { return drawGlyphs_.size(); }
  size_t drawMeshVertexCapacity() const   { return drawMeshVerts_.size(); }
  size_t drawSpatialVertexCapacity() const { return drawSpatialVerts_.size(); }
  void commitDrawList(size_t cmdCount, size_t glyphCount, size_t meshVertCount,
                      size_t spatialVertCount);
  /// Legacy copying path.
  void submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const canvas::GlyphInstance *glyphs, size_t glyphCount,
                      const canvas::MeshVertex *meshVerts, size_t meshVertCount,
                      const canvas::SpatialVertex *spatialVerts,
                      size_t spatialVertCount);

  // ─── Shared-memory arena ─────────────────────────────────────────────

  /// Renders whatever another process publishes into the arena named `id`,
  /// instead of this window's own arena.
  ///
  /// The two are mutually exclusive by construction rather than by rule: once
  /// attached, `repaint()` reads the arena and never looks at the local
  /// vectors, so a producer in this process and one in another cannot fight
  /// over the same window.
  bool attachDrawArena(const std::string &id);
  void detachDrawArena();
  bool hasDrawArena() const { return arena_ != nullptr; }

  // ─── Input ───────────────────────────────────────────────────────────────

  bool pollInputEvent(canvas::InputEvent &out);
  int  pendingDroppedFileCount();
  std::string pendingDroppedFile(int index);

  /// Queues an event that arrived already formed, rather than one derived
  /// from a device here.
  ///
  /// What a client needs, and the only way some events can reach it at all:
  /// `Resize`, `NodeHover`, `NodeScroll` and `NodeAnimationDone` are produced
  /// by a renderer looking at its own retained scene, and there is no local
  /// device to synthesize them from. Even for the ones `pointerMove` and
  /// friends could cover, going through those would re-derive — coalescing
  /// aside — decisions the renderer has already made.
  ///
  /// Coalesced the same way the local paths are, because the reason is the
  /// same on either side of a boundary: only the newest pointer position or
  /// node offset says anything the older ones did not.
  void postInputEvent(uint32_t kind, float x, float y, int32_t button, int32_t mods);

  void pointerMove(float x, float y);
  void pointerButton(int button, bool pressed, float x, float y, int mods = 0);
  void keyEvent(int key, int action, int mods);
  void textInput(const std::string &utf8);
  void charInput(unsigned int codepoint);
  void scroll(float dx, float dy);

  /// Scrolls a retained container with a notch the producer did not want.
  ///
  /// `scroll` declines outright when a producer-claimed node is under the
  /// pointer, because only the producer knows whether its widget will take
  /// that notch. This is the answer coming back: nothing did, so the
  /// containers around it may have it after all. Returns whether anything
  /// moved.
  bool scrollSceneUnclaimed(float dx, float dy);

  /// Consumes "this window needs redrawing for a reason of its own".
  ///
  /// Set when the renderer moves a scene node without the producer — a
  /// scroll today, an animation later. The frame loop has no other way to
  /// know: nothing was published and no input was queued, because the whole
  /// point is that the producer was not involved.
  bool takeInternalRepaint()
  {
    const bool was = internalRepaint_;
    internalRepaint_ = false;
    return was;
  }

  // ─── Window ──────────────────────────────────────────────────────────────

  bool windowShouldClose() const;
  void requestClose();

  /// Resizes a client window, queueing the `Resize` its producer needs to
  /// re-lay-out. Client only — a window with a renderer takes its size from
  /// the swapchain, and a second source of truth for it is a bug.
  ///
  /// This is the seam the compositor drives once the two processes are
  /// talking: a client has no surface to learn its own size from, so being
  /// told is the only way it can know.
  void setClientSize(float width, float height);

  void setWindowFrame(int x, int y, int width, int height);
  void setWindowVisible(bool visible);
  bool isVisible() const { return visible_; }
  bool isIconified() const;
  void framebufferSize(float &outW, float &outH) const;
  uint32_t x11WindowId() const;

  void setViewTransform(float zoom, float panX, float panY);

  std::string clipboardText() const;
  void setClipboardText(const std::string &text);

  // ─── Readback ────────────────────────────────────────────────────────────

  void readPixels(uint8_t *dst, size_t dstSize);
  void captureFrame(uint8_t *dst, size_t dstSize);
  bool capturePng(std::vector<uint8_t> &outPng, int x, int y, int w, int h,
                  int maxSide, int *outW, int *outH);

 private:
  void installGlfwCallbacks();
  void queueRefreshEvent();
  /// Steps scene-node animations and queues the resulting `NodeScroll`
  /// events. Once per repaint, before the frame is drawn.
  void stepSceneAnimations();

  /// See the definition: turns "more content arrived" into one more frame for
  /// a scroll parked at the edge of what had been drawn.
  void noteSceneResume();
  /// Re-answers which node is under the pointer, repainting and telling the
  /// producer if the answer changed.
  void noteSceneHover(float x, float y);
  /// A view over whatever the producer last committed.
  canvas::DrawList currentDrawList() const;

  uint32_t     id_ = 0;
  GLFWwindow  *glfw_ = nullptr;
  std::unique_ptr<RenderWindow> render_;
  bool visible_ = false;

  /// Client-only size and close flag. A rendered window keeps both in the
  /// renderer — the swapchain extent and GLFW's should-close — and asking two
  /// places would let them disagree.
  float clientW_ = 0.f;
  float clientH_ = 0.f;
  bool  clientClose_ = false;

  /// Set when this window is driven by another process. Held by pointer so
  /// the common case costs nothing and `draw_arena.hpp` stays out of the
  /// header's required includes.
  std::unique_ptr<canvas::ipc::DrawArena> arena_;
  /// The last frame acquired from the arena, kept mapped between publishes.
  /// A resize repaints, and the producer has usually said nothing new by
  /// then — re-presenting the frame we already hold is what stops that from
  /// flashing an empty window.
  canvas::DrawList arenaFrame_{};
  bool             arenaHasFrame_ = false;

  // Immediate draw list, authored by the producer each dirty frame.
  std::vector<canvas::DrawCommand>   drawCmds_;
  std::vector<canvas::GlyphInstance> drawGlyphs_;
  std::vector<canvas::MeshVertex>    drawMeshVerts_;
  std::vector<canvas::SpatialVertex> drawSpatialVerts_;
  size_t drawCmdCount_ = 0;
  size_t drawGlyphCount_ = 0;
  size_t drawMeshVertCount_ = 0;
  size_t drawSpatialVertCount_ = 0;

  // GLFW callbacks vs the consuming loop — protect the queue so Resize / Key /
  // Mouse are not lost.
  mutable std::mutex             inputMu_;
  std::deque<canvas::InputEvent> inputEvents_;
  /// Paths from the most recent drop, pulled by index while handling the
  /// FileDrop event they were queued alongside.
  std::vector<std::string> droppedPaths_;
  bool pointerDown_ = false;  // gates MouseMove queueing
  /// Last known pointer position, for input that carries none of its own.
  float pointerX_ = -1.f;
  float pointerY_ = -1.f;
  /// See `takeInternalRepaint`.
  bool internalRepaint_ = false;
  /// Reused across frames so an animating window allocates nothing.
  std::vector<canvas::SceneNodeOffset> sceneMovedScratch_;
  std::vector<uint32_t>                sceneFinishedScratch_;

  /// Modifier state, tracked per window because each window gets its own key
  /// callback and only the focused one is receiving them.
  bool shiftDown_ = false;
  bool ctrlDown_  = false;

  // Whole-window camera (layout stays at zoom=1; the vertex shader applies it).
  float viewZoom_ = 1.f;
  float viewPanX_ = 0.f;
  float viewPanY_ = 0.f;
};
