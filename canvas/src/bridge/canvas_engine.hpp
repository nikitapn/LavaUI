#pragma once

// C++-first public API for the editor engine. Prefer this over the C API
// when calling from C++ or Swift C++ interop. The C API in canvas_c_api.h
// is a thin wrapper for targets that still need plain C.

#include "../util/result.hpp"
#include "../render/draw_command.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Equivalent to SWIFT_RETURNS_INDEPENDENT_VALUE from <swift/bridging>. Keep it
// local because the SwiftPM Clang importer does not add Swift's C++ header
// directory to this package's include search path.
#if defined(__has_attribute) && __has_attribute(swift_attr)
#define CANVAS_SWIFT_UNSAFE_POINTER __attribute__((swift_attr("import_unsafe")))
#else
#define CANVAS_SWIFT_UNSAFE_POINTER
#endif

class Application;

namespace canvas {

// Named specializations so Swift can import/construct them. The primary
// `std::vector<T>` template is unavailable to Swift (ClangImporter +
// libstdc++ `vector<bool>`), but a `using` alias of a concrete
// specialization imports cleanly — construct, push_back, iterate, return.
using U8Vector = std::vector<std::uint8_t>;
using StringVector = std::vector<std::string>;

/// CPU-side decode result for `Engine::decodeImage` (no Vulkan).
struct DecodedImage {
  U8Vector pixels; // RGBA8, size == width * height * 4 when valid
  std::uint32_t width = 0;
  std::uint32_t height = 0;

  bool valid() const
  {
    return width > 0 && height > 0
           && pixels.size() == static_cast<size_t>(width) * height * 4;
  }
};

/// Owns the windowed (or offscreen) Application and optional present thread.
class Engine {
 public:
  Engine();
  ~Engine();

  Engine(const Engine &) = delete;
  Engine &operator=(const Engine &) = delete;
  Engine(Engine &&) noexcept;
  Engine &operator=(Engine &&) noexcept;

  /// Single GLFW+Vulkan window with ImGui shell + continuous present.
  [[nodiscard]] VoidResult openWindow(const std::string &assetsRoot,
                                      uint32_t width, uint32_t height,
                                      const std::string &title);

  /// Headless offscreen (tests / PNG smoke).
  [[nodiscard]] VoidResult openOffscreen(const std::string &assetsRoot,
                                         uint32_t width, uint32_t height);

  void close();
  bool isOpen() const;

  /// Signal the window to close; the app loop exits on the next iteration.
  void requestClose();

  /// Drive the window from the caller's thread. `timeoutSeconds`: negative
  /// blocks until an event arrives, 0 polls, positive waits up to that long.
  /// Blocking is what keeps an idle UI at zero CPU while still waking on
  /// input immediately.
  void pumpEvents(double timeoutSeconds);

  /// Thread-safe: unblock a waiting `pumpEvents` (GLFW empty event).
  /// Used by the agent socket watcher so TCP requests don't wait on a mouse tick.
  void wakeEventLoop();

  // ─── Windows ─────────────────────────────────────────────────────────────
  //
  // Per-window calls take a trailing `windowId`; 0 means the first window, so
  // single-window callers never mention it. Ids come from `openWindow` and are
  // never reused, so a handle to a closed window fails to resolve rather than
  // addressing whatever opened after it.

  /// Opens an additional window on the same device — one GPU, one font atlas,
  /// one texture cache, however many surfaces. Returns its id, or 0.
  ///
  /// Starts hidden: showing a window before a frame has been drawn into it
  /// presents an undefined swapchain image. Call `setWindowVisible` after the
  /// first `renderFrame`.
  uint32_t openWindow(uint32_t width, uint32_t height, const std::string &title);

  /// Closes one window. The device, and every other window, survive.
  void closeWindow(uint32_t windowId);

  size_t windowCount() const;
  /// Id of the window at `index` in creation order, or 0 if out of range.
  uint32_t windowIdAt(size_t index) const;

  /// Whether this window has been asked to close (its titlebar X, a WM
  /// request). Closing the last one is what ends an app; closing any other is
  /// just `closeWindow`.
  ///
  /// False for a window that is already gone — "asked to close" and "does not
  /// exist" are different questions, and `windowCount` answers the second.
  bool windowShouldClose(uint32_t windowId = 0) const;

  /// Render and present one frame.
  bool renderFrame(uint32_t windowId = 0);

  /// Renders this window from a shared-memory draw arena written by another
  /// process (`canvas::ipc::DrawArena`), instead of from a draw list
  /// submitted through `commitDrawList`.
  ///
  /// The arena has to exist already — the producer creates it, the renderer
  /// attaches. Returns false if it is missing or malformed.
  bool attachDrawArena(const std::string &id, uint32_t windowId = 0);
  void detachDrawArena(uint32_t windowId = 0);

  void setWindowFrame(int x, int y, int width, int height, uint32_t windowId = 0);
  void setWindowVisible(bool visible, uint32_t windowId = 0);
  bool isWindowVisible(uint32_t windowId = 0) const;

  // ─── Declarative UI (Swift tree → Yoga + TextRenderer) ────────────────
  bool repaint(uint32_t windowId = 0);
  void readPixels(uint8_t *dst, size_t dstSize);

  /// Agent/automation: capture resolve as PNG (base64). Empty on failure.
  /// Region in framebuffer pixels; w or h <= 0 → full frame.
  /// maxSide > 0 downsamples so the longer encoded side is ≤ maxSide.
  /// outW/outH receive the encoded size when non-null.
  std::string capturePngBase64(int x, int y, int w, int h, int maxSide = 0,
                               int *outW = nullptr, int *outH = nullptr,
                               uint32_t windowId = 0);

  /// Inject synthetic pointer events (same queue as GLFW callbacks).
  void pointerMove(float x, float y, uint32_t windowId = 0);
  void pointerButton(int button, bool pressed, float x, float y, uint32_t windowId = 0);
  /// Inject wheel/trackpad delta (notches), coalesced with real scroll input.
  void pointerScroll(float dx, float dy, uint32_t windowId = 0);

  /// Inject keyboard / text (GLFW key codes; action 0/1/2 = release/press/repeat).
  void keyEvent(int key, int action, int mods, uint32_t windowId = 0);
  /// UTF-8 string → one Text event per Unicode scalar (focused field path).
  void textInput(const std::string &utf8, uint32_t windowId = 0);

  /// Legacy copied submission path.
  /// Text commands carry `param` = first glyph index and `w` = glyph count
  /// into `glyphs`. Mesh commands carry the same pair into `meshVerts`. Swift
  /// shapes; the renderer only looks up atlas entries / triangulates.
  void submitDrawList(const DrawCommand *cmds, size_t cmdCount,
                      const GlyphInstance *glyphs, size_t glyphCount,
                      const MeshVertex *meshVerts, size_t meshVertCount,
                      const SpatialVertex *spatialVerts, size_t spatialVertCount,
                      uint32_t windowId = 0);

  /// C++-owned reusable frame arena. Swift may write to these pointers until
  /// the next ensure call (which may reallocate) or Engine destruction. Commit
  /// publishes only the initialized prefixes; it performs no element copy.
  void ensureDrawListCapacity(size_t cmdCapacity, size_t glyphCapacity,
                              size_t meshVertCapacity, size_t spatialVertCapacity,
                              uint32_t windowId = 0);
  DrawCommand *drawCommandData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  GlyphInstance *drawGlyphData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  MeshVertex *drawMeshVertexData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  SpatialVertex *drawSpatialVertexData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  size_t drawCommandCapacity(uint32_t windowId = 0) const;
  size_t drawGlyphCapacity(uint32_t windowId = 0) const;
  size_t drawMeshVertexCapacity(uint32_t windowId = 0) const;
  size_t drawSpatialVertexCapacity(uint32_t windowId = 0) const;
  void commitDrawList(size_t cmdCount, size_t glyphCount,
                      size_t meshVertCount, size_t spatialVertCount,
                      uint32_t windowId = 0);

  /// Pop one raw input event (mouse / resize). Returns false if empty.
  bool pollInputEvent(InputEvent &out, uint32_t windowId = 0);

  /// Paths from the most recent FileDrop event — see
  /// `canvas::InputEventKind::FileDrop`. Valid until the next drop.
  StringVector pendingDroppedFiles(uint32_t windowId = 0);

  /// Current swapchain extent in pixels.
  void framebufferSize(float &outW, float &outH, uint32_t windowId = 0) const;

  /// Whole-window camera (vertex push constants). Layout/hit-test stay unscaled.
  void setViewTransform(float zoom, float panX, float panY, uint32_t windowId = 0);

  /// Load TextRenderer face for draw-list text. Called from Swift FontStore
  /// after open — C++ does not choose a default path.
  [[nodiscard]] VoidResult loadFont(const std::string &path, float pixelSize);

  /// Registers a face for draw-list glyph lookup and returns its id, or -1.
  /// Idempotent per (path, pixelSize). Swift stamps this id into every
  /// GlyphInstance so the renderer resolves ids against the right face.
  int registerFont(const std::string &path, float pixelSize);

  /// System clipboard (GLFW-backed; empty when headless).
  std::string clipboardText() const;
  void setClipboardText(const std::string &text);

  /// Load PNG/JPEG for `Image` draw commands. Returns texture id (>0) or -1.
  int loadTexture(const std::string &path);

  /// Releases one reference to a texture. The GPU memory is freed only after
  /// every in-flight frame that could reference it has retired — see
  /// `RenderDevice::destroyImageDeferred`. Atlased images return their cell instead.
  void unloadTexture(const std::string &path);

  /// Decodes an image file to RGBA8 **without touching RenderDevice**, so it is safe
  /// to call from a worker thread. Empty/`valid()==false` if the file will not
  /// decode. This is the expensive half of loading; `uploadTexture` is the
  /// half that must stay on the device thread.
  ///
  /// `maxPixelSize` (0 = native) caps the longer edge, preserving aspect. Pass
  /// the size the image will actually be *drawn* at: a 300px cover rendered
  /// into a 140pt box costs 4.5× the pixels for no visible gain, and — because
  /// `ImageAtlas` refuses anything wider than one cell — is what pushes every
  /// such image out of the atlas and onto its own descriptor binding.
  static DecodedImage decodeImage(const std::string &path,
                                  uint32_t maxPixelSize = 0);

  /// Uploads pre-decoded pixels under `key`. Device thread only.
  int uploadTexture(const std::string &key, const uint8_t *rgba,
                    uint32_t width, uint32_t height);
  int uploadTexture(const std::string &key, const U8Vector &rgba,
                    uint32_t width, uint32_t height);

  /// Whether `key` is already resident, so a caller can skip decoding.
  bool hasTexture(const std::string &key) const;
  bool textureSize(uint32_t textureId, float &outW, float &outH) const;

  /// Low-level access for advanced use; may be null if closed.
  Application *application();

  // ─── App menu (Linux DBusMenu / global panel) ───────────────────────────

  /// X11 window id for the GLFW surface, or 0 if not X11 / no window.
  uint32_t x11WindowId() const;

  /// True if a global-menu registrar is on the session bus (and lib linked).
  static bool appMenuRegistrarAvailable();

  /// Attach DBusMenu server + RegisterWindow. No-op / false without deps.
  bool appMenuAttach();

  void appMenuDetach();
  bool appMenuIsAttached() const;
  void appMenuPoll();

  void appMenuBeginUpdate();
  void appMenuBeginMenu(const std::string &id, const std::string &title);
  void appMenuEndMenu();
  /// checked: -1 none, 0 unchecked, 1 checked.
  void appMenuAddItem(const std::string &id, const std::string &title,
                      bool enabled, int checked);
  void appMenuAddSeparator();
  void appMenuCommitUpdate();

  /// Pop panel activation (MenuID string). Empty string if none.
  std::string appMenuPopActivation();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
