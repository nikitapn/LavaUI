#pragma once

// C++-first public API for the editor engine. Prefer this over the C API
// when calling from C++ or Swift C++ interop. The C API in canvas_c_api.h
// is a thin wrapper for targets that still need plain C.

#include "../util/result.hpp"
#include "../render/draw_command.hpp"
#include "../render/export_format.hpp"

#include <cstdint>
#include <cstring>
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

class DmabufImage;

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

  /// Copies the whole buffer out in one memcpy. Returns bytes written.
  ///
  /// Swift can subscript `pixels` directly, but every element crosses the
  /// interop boundary as its own unspecialized call — a 300x297 RGBA image is
  /// 356,400 of them, which measured at 2.7s against a 2ms decode and put the
  /// compositor's `RegisterImage` past its RPC timeout, so no client could
  /// start. This moves the same bytes as one block.
  ///
  /// Written this way round because C++ interop imports pointer *parameters*
  /// but not pointer *returns*; the caller owns the destination.
  std::size_t copyTo(std::uint8_t *dst, std::size_t capacity) const
  {
    const std::size_t n = pixels.size() < capacity ? pixels.size() : capacity;
    if (dst != nullptr && n > 0) std::memcpy(dst, pixels.data(), n);
    return n;
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

  /// Headless, able to render surfaces another driver reads.
  ///
  /// The compositor path: canvas draws a client's window and a wlroots scene
  /// graph shows it, with no copy between them. Same as `openOffscreen` except
  /// that the GPU is not ours to choose — it has to be the one the consumer
  /// already renders on — and a frame's destination is a shared image rather
  /// than a staging buffer.
  ///
  /// Opens no window. One device serves every surface, which is the point:
  /// a compositor has one GPU and as many surfaces as it has clients, and they
  /// share a glyph atlas and a texture cache rather than each bringing up a
  /// device of its own. See `Application::initExported`.
  ///
  /// `drmFd` is the consumer's DRM node (wlroots: `wlr_renderer_get_drm_fd`);
  /// it is read during the call and not owned here.
  /// `consumerFormats` is what that consumer can import, one entry per format
  /// in `DmabufImage::exportFormats()` it supports, in that order.
  /// `sampleCap` limits MSAA; 0 keeps the engine default. See
  /// `RenderDevice::setSampleCap` for why a compositor has an opinion.
  [[nodiscard]] VoidResult openExported(
    const std::string &assetsRoot, int drmFd,
    const std::vector<ExportFormatSupport> &consumerFormats,
    uint32_t sampleCap = 0);

  /// Opens one exported surface. Returns its window id, or 0.
  uint32_t openExportedWindow(uint32_t width, uint32_t height);

  /// Resizes an exported surface. True if it changed. Its buffer is only a new
  /// one when the window outgrew the old — compare `exportedImage` to find
  /// out. See `Application::resizeExportedWindow`.
  bool resizeExportedWindow(uint32_t windowId, uint32_t width, uint32_t height);

  /// Attributes of a surface's exported buffer, or null. At least the window's
  /// size, and usually larger; the frame sits in its top-left corner.
  const DmabufImage *exportedImage(uint32_t windowId) const;

  /// Says that whoever shows these surfaces waits on each frame's fence, so a
  /// frame can end at the submit instead of at the GPU. The promise is only
  /// kept by collecting `takeFrameFence` after every frame — see
  /// `RenderDevice::setExportFenceHonoured`.
  void setExportFenceHonoured(bool honoured);

  /// The sync_file for this surface's last exported frame, or -1 when there is
  /// none and the frame is already finished. The caller owns the fd.
  int takeFrameFence(uint32_t windowId);

  /// Blocks until this surface's submitted frames have finished — the fallback
  /// for a consumer that asked for a fence and could not be given one.
  void waitForFrames(uint32_t windowId);

  /// Client: lays out and emits frames for another process to draw. No
  /// Vulkan, no window, no GPU.
  ///
  /// Distinct from `openOffscreen`, which is just as windowless but still
  /// brings up a device and renders to a readback target. A client renders
  /// nothing at all — `renderFrame` succeeds and draws nowhere, and the
  /// frame's actual destination is the draw arena.
  ///
  /// Everything a client cannot answer for itself is told to it: its size
  /// (`setClientSize`) and its input (`pointerMove`, `keyEvent`, … — the same
  /// entry points the agent server injects through, which is what makes a
  /// client testable before there is a compositor on the other end).
  [[nodiscard]] VoidResult openClient(uint32_t width, uint32_t height);

  /// Resizes a client window and queues the `Resize` its producer needs.
  /// No-op unless this engine was opened with `openClient`.
  void setClientSize(float width, float height, uint32_t windowId = 0);

  /// Sets the minimum interactive size of a local GLFW window. Zero means no
  /// constraint on that axis; no-op in client mode.
  void setMinimumSize(float width, float height, uint32_t windowId = 0);

  /// Queues an event that arrived already formed — from a renderer in
  /// another process. See `AppWindow::postInputEvent`.
  void postInputEvent(uint32_t kind, float x, float y, int32_t button,
                      int32_t mods, uint32_t windowId = 0);

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

  /// Consumes "this window needs redrawing for a reason of its own".
  ///
  /// The renderer moves scene nodes on its own — a scroll today — without
  /// the producer publishing anything or any input being queued, so a frame
  /// loop driven by those two signals alone would never repaint. This is the
  /// third signal.
  bool takeInternalRepaint(uint32_t windowId = 0);

  /// Offers a wheel notch to the retained scroll containers under the pointer,
  /// after the producer has found nothing of its own that wanted it.
  ///
  /// The renderer takes the wheel first and normally keeps it — that is what
  /// lets a list scroll while this process is busy. It defers only where the
  /// producer has declared a wheel handler of its own, because whether that
  /// handler will use *this* notch is a question only the producer can
  /// answer. This is the answer coming back.
  bool scrollSceneUnclaimed(float dx, float dy, uint32_t windowId = 0);

  /// Render and present one frame.
  bool renderFrame(uint32_t windowId = 0);

  /// Brackets `renderFrame` calls that run concurrently, one thread per
  /// window. See `Application::beginFrameGroup` for what this buys and what
  /// it requires. A caller rendering one window at a time needs neither.
  void beginFrameGroup();
  void endFrameGroup();

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

  /// Rounds a window's corners, applied as the last step of every frame.
  /// `radius` 0 is square. `top`/`bottom` select which pair is rounded.
  void setWindowCornerRadius(float radius, bool top, bool bottom,
                             uint32_t windowId = 0);

  /// The pointer image over a window, as a `CursorShape` ordinal (LavaUI owns
  /// the numbering; see `Cursor.swift`). No-op for a client window, which has
  /// no pointer of its own to set.
  void setCursorShape(uint32_t shape, uint32_t windowId = 0);
  bool isWindowVisible(uint32_t windowId = 0) const;

  // ─── Declarative UI (Swift tree → Yoga + TextRenderer) ────────────────
  bool repaint(uint32_t windowId = 0);

  /// Takes the next frame published into this window's arena, without drawing
  /// it, and says whether there was one. What a polling consumer asks before
  /// deciding to render. See `AppWindow::pollDrawArena`.
  bool pollDrawArena(uint32_t windowId = 0);

  /// Frames this window has actually drawn. See `Application::frameCounter` —
  /// it does not advance on a repaint that found nothing new to draw, which is
  /// what makes it usable as "is there anything to show?".
  uint64_t frameCounter(uint32_t windowId = 0) const;

  /// The opaque part of this window's last frame, in window pixels, already
  /// inset for rounded corners. False when nothing was claimed.
  ///
  /// What a compositor needs to stop blending a surface it does not have to —
  /// see `DrawCommandKind::OpaqueBounds`.
  bool opaqueBounds(uint32_t windowId, float &x, float &y, float &w,
                    float &h) const;
  void readPixels(uint8_t *dst, size_t dstSize);

  /// Agent/automation: capture resolve as PNG (base64). Empty on failure.
  /// Region in framebuffer pixels; w or h <= 0 → full frame.
  /// maxSide > 0 downsamples so the longer encoded side is ≤ maxSide.
  /// outW/outH receive the encoded size when non-null.
  std::string capturePngBase64(int x, int y, int w, int h, int maxSide = 0,
                               int *outW = nullptr, int *outH = nullptr,
                               uint32_t windowId = 0);

  /// The same capture as PNG bytes, for a caller that is not about to put it
  /// in JSON. Empty on failure. A compositor capturing a client's window
  /// wants these — base64 is the agent protocol's business, not the
  /// renderer's, and encoding it here would cost a third of the bytes on the
  /// way to a process that only has to decode them again.
  U8Vector capturePng(int x, int y, int w, int h, int maxSide = 0,
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
                              size_t gradientCapacity, uint32_t windowId = 0);
  DrawCommand *drawCommandData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  GlyphInstance *drawGlyphData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  MeshVertex *drawMeshVertexData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  SpatialVertex *drawSpatialVertexData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  GradientDesc *drawGradientData(uint32_t windowId = 0) CANVAS_SWIFT_UNSAFE_POINTER;
  size_t drawCommandCapacity(uint32_t windowId = 0) const;
  size_t drawGlyphCapacity(uint32_t windowId = 0) const;
  size_t drawMeshVertexCapacity(uint32_t windowId = 0) const;
  size_t drawSpatialVertexCapacity(uint32_t windowId = 0) const;
  size_t drawGradientCapacity(uint32_t windowId = 0) const;
  void commitDrawList(size_t cmdCount, size_t glyphCount,
                      size_t meshVertCount, size_t spatialVertCount,
                      size_t gradientCount, uint32_t windowId = 0);

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

  /// The full form of the above: a face inside a collection, a 26.6 size, and
  /// a `canvas::RasterFlags` hinting selection.
  ///
  /// Idempotent per `canvas::FontKey` — the file's *contents*, not its path.
  /// Named differently rather than overloaded because Swift's C++ interop
  /// imports overload sets by mangled name, and two `registerFont`s differing
  /// only in arity read badly on that side.
  int registerFace(const std::string &path, uint32_t pixelSize26_6,
                   uint32_t faceIndex, uint32_t rasterFlags);

  /// System clipboard (GLFW-backed; empty when headless).
  std::string clipboardText() const;
  void setClipboardText(const std::string &text);

  /// Load PNG/JPEG for `Image` draw commands. Returns texture id (>0) or -1.
  int loadTexture(const std::string &path);

  /// Releases one ownership reference. At zero the entry goes dormant rather
  /// than away: it keeps its id and its pixels, and `reviveTexture` picks it
  /// up again for free. Eviction from there is LRU and runs on whichever
  /// resource is actually scarce — a byte budget for standalone images, atlas
  /// occupancy for packed ones. Either way the GPU memory or the cell is
  /// released only once every frame that could still sample it has retired.
  void unloadTexture(const std::string &path);

  /// Releases and drops, for a key with a generation in it that nothing will
  /// ever ask for again. See `TextureManager::discardTexture`.
  void discardTexture(const std::string &key);

  /// Decodes an image file to RGBA8 **without touching RenderDevice**, so it is safe
  /// to call from a worker thread. Empty/`valid()==false` if the file will not
  /// decode. This is the expensive half of loading; `uploadTexture` is the
  /// half that must stay on the device thread.
  ///
  /// `maxPixelSize` (0 = native) caps the longer edge, preserving aspect. Pass
  /// the size the image will actually be *drawn* at: a 300px cover rendered
  /// into a 140pt box costs 4.5× the pixels for no visible gain. It also
  /// decides how the image is stored — `ImageAtlas` picks the tightest of its
  /// size classes that the decode fits, and refuses anything above the
  /// largest, which leaves the caller holding a standalone texture.
  static DecodedImage decodeImage(const std::string &path,
                                  uint32_t maxPixelSize = 0);

  /// The same decode, from bytes already in memory — an image that was
  /// downloaded, generated, or unpacked from an archive and never had a path.
  /// Encoded bytes (PNG, JPEG, …), not raw pixels: the format is sniffed, the
  /// way it is for a file.
  static DecodedImage decodeImageData(const uint8_t *bytes, size_t byteCount,
                                      uint32_t maxPixelSize = 0);

  /// Encodes RGBA8 to a PNG. `maxSide` 0 is native. Empty `pixels` on failure.
  /// Same `copyTo` contract as `DecodedImage` so Swift can lift the bytes
  /// in one memcpy. Used when a client has raw pixels (an SNI pixmap) and
  /// must `RegisterImageData` them — the compositor only accepts encoded
  /// files, and there is no GPU here to `uploadTexture`.
  static DecodedImage encodeRgbaPng(const uint8_t *rgba, uint32_t width,
                                    uint32_t height, uint32_t maxSide = 0);

  /// Uploads pre-decoded pixels under `key`. Device thread only.
  int uploadTexture(const std::string &key, const uint8_t *rgba,
                    uint32_t width, uint32_t height);
  int uploadTexture(const std::string &key, const U8Vector &rgba,
                    uint32_t width, uint32_t height);

  /// Whether `key` is already resident, so a caller can skip decoding. Only a
  /// hint — see `reviveTexture` for the form that is safe to act on.
  bool hasTexture(const std::string &key) const;

  /// Takes a reference on `key` if it is already resident, reviving it from
  /// the dormant cache, and reports its pixel size. Returns the texture id, or
  /// -1 if the key is absent and the caller must decode after all.
  ///
  /// Lookup and reference happen under one lock, which `hasTexture` followed
  /// by `loadTexture` cannot promise: an eviction in the gap turns the second
  /// call into a filesystem load of the key, ignoring whatever size cap the
  /// caller had decoded to.
  int reviveTexture(const std::string &key, uint32_t &outWidth,
                    uint32_t &outHeight);

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

  /// The same, for a window this process names itself: a compositor client
  /// has no X11 id, and its surface id is what the panel knows it by.
  bool appMenuAttachWindow(uint32_t windowId);

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

  // ─── Menu import (the panel side of the same protocol) ──────────────────
  //
  // A panel owns the registrar and reads other applications' menus; an
  // application exports one. Both live here because both are one process's
  // engine away from the code that needs them, and neither is worth a second
  // bridge. See `MenuImportHost`.

  /// Own a registrar name and start serving. False without a session bus or
  /// a free name.
  bool menuImportStart();
  /// Which name was claimed, or empty.
  std::string menuImportBusName();
  /// Whose menu to show; 0 for none. Optional service/path from kde-appmenu.
  void menuImportSetActiveWindow(uint32_t windowId,
                                 std::string menuService = {},
                                 std::string menuObjectPath = {});
  /// Iterate GLib once. Call every frame while a panel is showing a menu.
  void menuImportPoll();
  /// Bumped whenever the imported menu changes.
  uint64_t menuImportRevision() const;

  size_t menuImportItemCount() const;
  int32_t menuImportItemId(size_t index) const;
  int32_t menuImportItemParent(size_t index) const;
  std::string menuImportItemLabel(size_t index) const;
  bool menuImportItemEnabled(size_t index) const;
  bool menuImportItemSeparator(size_t index) const;
  bool menuImportItemHasSubmenu(size_t index) const;
  /// -1 none, 0 unchecked, 1 checked.
  int menuImportItemChecked(size_t index) const;

  /// Run the item, in the application that owns it.
  void menuImportActivate(int32_t itemId);
  /// Ask for a submenu's contents before opening it.
  void menuImportAboutToShow(int32_t itemId);

  // ─── Status Notifier (system tray) ─────────────────────────────────────
  //
  // Panel owns `org.kde.StatusNotifierWatcher`. See `StatusNotifierHost`.

  bool statusNotifierStart();
  bool statusNotifierIsServing() const;
  void statusNotifierPoll();
  uint64_t statusNotifierRevision() const;
  size_t statusNotifierItemCount() const;
  std::string statusNotifierItemKey(size_t index) const;
  std::string statusNotifierItemId(size_t index) const;
  std::string statusNotifierItemTitle(size_t index) const;
  std::string statusNotifierItemStatus(size_t index) const;
  std::string statusNotifierItemIconName(size_t index) const;
  std::string statusNotifierItemIconPath(size_t index) const;
  bool statusNotifierItemIsMenu(size_t index) const;
  int statusNotifierItemIconWidth(size_t index) const;
  int statusNotifierItemIconHeight(size_t index) const;
  size_t statusNotifierItemIconRgbaSize(size_t index) const;
  size_t statusNotifierItemIconRgbaCopy(size_t index, uint8_t *out,
                                        size_t cap) const;
  void statusNotifierActivate(const std::string &key, int x, int y);
  void statusNotifierContextMenu(const std::string &key, int x, int y);
  void statusNotifierSecondaryActivate(const std::string &key, int x, int y);
  // ─── Notifications ───────────────────────────────────────────────────
  //
  // The panel serves `org.freedesktop.Notifications`. See `NotificationHost`.

  bool notificationsStart();
  bool notificationsIsServing() const;
  /// Pumps the bus *and* retires whatever expired. Every frame.
  void notificationsPoll();
  uint64_t notificationsRevision() const;
  size_t notificationsCount() const;
  uint32_t notificationId(size_t index) const;
  std::string notificationAppName(size_t index) const;
  std::string notificationSummary(size_t index) const;
  std::string notificationBody(size_t index) const;
  std::string notificationIconPath(size_t index) const;
  int notificationIconWidth(size_t index) const;
  int notificationIconHeight(size_t index) const;
  size_t notificationIconRgbaSize(size_t index) const;
  size_t notificationIconRgbaCopy(size_t index, uint8_t *out, size_t cap) const;
  /// 0 low, 1 normal, 2 critical. Critical never expires on its own.
  uint8_t notificationUrgency(size_t index) const;
  int64_t notificationRemainingMs(size_t index) const;
  size_t notificationActionCount(size_t index) const;
  std::string notificationActionKey(size_t index, size_t action) const;
  std::string notificationActionLabel(size_t index, size_t action) const;
  void notificationInvokeAction(uint32_t id, const std::string &key);
  void notificationDismiss(uint32_t id);
  void notificationDismissAll();
  /// Holds every countdown while the pointer is over the stack.
  void notificationsSetPaused(bool paused);

  bool statusNotifierItemHasMenu(size_t index) const;
  /// Left click has nowhere to go but the menu — `ItemIsMenu`, or no
  /// `Activate` at all. See `StatusNotifierHost::itemPrefersMenu`.
  bool statusNotifierItemPrefersMenu(size_t index) const;
  bool statusNotifierOpenMenu(const std::string &key);
  void statusNotifierCloseMenu();
  uint64_t statusNotifierMenuRevision() const;
  size_t statusNotifierMenuItemCount() const;
  int32_t statusNotifierMenuItemId(size_t index) const;
  int32_t statusNotifierMenuItemParent(size_t index) const;
  std::string statusNotifierMenuItemLabel(size_t index) const;
  bool statusNotifierMenuItemEnabled(size_t index) const;
  bool statusNotifierMenuItemSeparator(size_t index) const;
  bool statusNotifierMenuItemHasSubmenu(size_t index) const;
  int statusNotifierMenuItemChecked(size_t index) const;
  void statusNotifierMenuActivate(int32_t itemId);
  void statusNotifierMenuAboutToShow(int32_t itemId);
  void statusNotifierScroll(const std::string &key, int delta,
                            const std::string &orientation);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
