#include "bridge/canvas_engine.hpp"

#include <stb_image.h>
#include <stb_image_resize2.h>

#include "application.hpp"
#include "menu/app_menu.hpp"
#include "menu/menu_import.hpp"
#include "menu/notification.hpp"
#include "menu/status_notifier.hpp"
#include "render/font_key.hpp"
#include "render/png_encode.hpp"
#include "render/svg_image.hpp"
#include "window/canvas_window.hpp"

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <type_traits>
#include <unordered_map>

namespace canvas {

struct Engine::Impl {
  /// `Client` shares the `offscreen` slot with `Offscreen` — both hold an
  /// `Application` directly rather than through a window host — which is why
  /// `withApp` needs no branch for it and the ~60 methods below inherit
  /// client mode for free. What separates the two is only how the
  /// `Application` was initialized.
  enum class Mode { None, Offscreen, Windowed, Client } mode = Mode::None;
  std::unique_ptr<Application> offscreen;
  std::unique_ptr<CanvasWindowHost> window;
  AppMenuHost appMenu;
  /// The panel's half of the same protocol. Built here rather than owned by
  /// whoever draws a panel, so a menu importer has the same lifetime as the
  /// engine that polls it — see `MenuImportHost`.
  MenuImportHost menuImport;
  /// System tray: StatusNotifierWatcher. Same lifetime rationale as menus.
  StatusNotifierHost statusNotifier;

  /// Desktop notifications, served for the session. See `NotificationHost`.
  NotificationHost notifications;

  /// Client-mode event wait. A client has no GLFW to park in, but it still
  /// has to block — a producer that spins is worse than one that is slow,
  /// and the frame loop's whole idle story is that waiting costs nothing.
  std::mutex              wakeMu;
  std::condition_variable wakeCv;
  bool                    woken = false;

  Application *app()
  {
    if (mode == Mode::Windowed) return window ? window->app() : nullptr;
    return offscreen.get();
  }

  template <typename Fn>
  auto withApp(Fn &&fn) -> decltype(fn(*static_cast<Application *>(nullptr)))
  {
    using R = decltype(fn(*static_cast<Application *>(nullptr)));
    if (mode == Mode::Windowed) {
      if (!window) {
        if constexpr (std::is_void_v<R>) return;
        else return R{};
      }
      // No lock, and no longer because there is only one thread — there is
      // not. `renderFrame` runs one worker per window inside a frame group,
      // and the control plane calls in on RPC threads besides.
      //
      // What makes this safe is that the lookup is read-only: the window list
      // is built and torn down on the frame loop's thread, between groups,
      // never while a call here is resolving. Serialisation belongs further
      // down, next to the state that actually changes — `RenderDevice`'s frame
      // and shared-state mutexes — not around every bridge call.
      //
      // A lock here used to be held by the render thread across a whole
      // vsync-blocked frame, which cost every call ~17ms median and up to
      // 200ms. That is what it would cost again.
      Application *a = window->app();
      if (!a) {
        if constexpr (std::is_void_v<R>) return;
        else return R{};
      }
      return fn(*a);
    }
    if (!offscreen) {
      if constexpr (std::is_void_v<R>) return;
      else return R{};
    }
    return fn(*offscreen);
  }
};

Engine::Engine() : impl_(std::make_unique<Impl>()) {}
Engine::~Engine() { close(); }
Engine::Engine(Engine &&) noexcept = default;
Engine &Engine::operator=(Engine &&) noexcept = default;

VoidResult Engine::openWindow(const std::string &assetsRoot, uint32_t width,
                              uint32_t height, const std::string &title)
{
  close();
  impl_->window = std::make_unique<CanvasWindowHost>();
  if (!impl_->window->open(assetsRoot, width, height, title)) {
    impl_->window.reset();
    return fail("Engine::openWindow failed");
  }
  impl_->mode = Impl::Mode::Windowed;
  return ok();
}

VoidResult Engine::openOffscreen(const std::string &assetsRoot, uint32_t width,
                                 uint32_t height)
{
  close();
  impl_->offscreen =
    std::make_unique<Application>(static_cast<int>(width), static_cast<int>(height));
  if (auto r = impl_->offscreen->init(assetsRoot); !r) {
    impl_->offscreen.reset();
    return r;
  }
  impl_->mode = Impl::Mode::Offscreen;
  return ok();
}

VoidResult Engine::openExported(const std::string &assetsRoot, int drmFd,
                                const std::vector<uint64_t> &importableModifiers)
{
  close();
  // No nominal size: every surface is opened with its own, and a device that
  // has no window has nothing to apply a default to.
  impl_->offscreen = std::make_unique<Application>(1, 1);
  if (auto r = impl_->offscreen->initExported(assetsRoot, drmFd,
                                              importableModifiers);
      !r) {
    impl_->offscreen.reset();
    return r;
  }
  // Offscreen as far as everything else is concerned: no window, no present
  // loop, frames driven by whoever asks for them. Only the destination differs.
  impl_->mode = Impl::Mode::Offscreen;
  return ok();
}

uint32_t Engine::openExportedWindow(uint32_t width, uint32_t height)
{
  return impl_->offscreen ? impl_->offscreen->openExportedWindow(width, height)
                          : 0;
}

bool Engine::resizeExportedWindow(uint32_t windowId, uint32_t width,
                                  uint32_t height)
{
  return impl_->offscreen
           ? impl_->offscreen->resizeExportedWindow(windowId, width, height)
           : false;
}

const DmabufImage *Engine::exportedImage(uint32_t windowId) const
{
  return impl_->offscreen ? impl_->offscreen->exportedImage(windowId) : nullptr;
}

void Engine::setExportFenceHonoured(bool honoured)
{
  if (impl_->offscreen) impl_->offscreen->setExportFenceHonoured(honoured);
}

int Engine::takeFrameFence(uint32_t windowId)
{
  return impl_->offscreen ? impl_->offscreen->takeFrameFence(windowId) : -1;
}

void Engine::waitForFrames(uint32_t windowId)
{
  if (impl_->offscreen) impl_->offscreen->waitForFrames(windowId);
}

VoidResult Engine::openClient(uint32_t width, uint32_t height)
{
  close();
  impl_->offscreen =
    std::make_unique<Application>(static_cast<int>(width), static_cast<int>(height));
  if (auto r = impl_->offscreen->initClient(); !r) {
    impl_->offscreen.reset();
    return r;
  }
  impl_->mode = Impl::Mode::Client;
  return ok();
}

void Engine::setClientSize(float width, float height, uint32_t windowId)
{
  impl_->withApp(
    [&](Application &app) { app.setClientSize(width, height, windowId); });
}

void Engine::setMinimumSize(float width, float height, uint32_t windowId)
{
  impl_->withApp(
    [&](Application &app) { app.setMinimumSize(width, height, windowId); });
}

void Engine::postInputEvent(uint32_t kind, float x, float y, int32_t button,
                            int32_t mods, uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.postInputEvent(kind, x, y, button, mods, windowId);
  });
}

void Engine::close()
{
  impl_->appMenu.detach();
  if (impl_->window) {
    impl_->window->close();
    impl_->window.reset();
  }
  if (impl_->offscreen) {
    impl_->offscreen->shutdown();
    impl_->offscreen.reset();
  }
  impl_->mode = Impl::Mode::None;
}

void Engine::pumpEvents(double timeoutSeconds)
{
  if (impl_->mode == Impl::Mode::Client) {
    // Same contract as the GLFW wait this stands in for: negative blocks
    // until something happens, 0 polls, positive waits at most that long.
    // A wake that arrived while the caller was working is not lost — it is
    // recorded in `woken` and returns immediately here, which is the
    // difference between a condition variable and a bare sleep.
    std::unique_lock lock(impl_->wakeMu);
    if (impl_->woken) {
      impl_->woken = false;
      return;
    }
    if (timeoutSeconds == 0) return;
    if (timeoutSeconds < 0) {
      impl_->wakeCv.wait(lock, [&] { return impl_->woken; });
    } else {
      impl_->wakeCv.wait_for(
        lock, std::chrono::duration<double>(timeoutSeconds),
        [&] { return impl_->woken; });
    }
    impl_->woken = false;
    return;
  }
  if (impl_->window) impl_->window->pumpEvents(timeoutSeconds);
}

void Engine::wakeEventLoop()
{
  if (impl_->mode == Impl::Mode::Client) {
    {
      std::lock_guard lock(impl_->wakeMu);
      impl_->woken = true;
    }
    impl_->wakeCv.notify_all();
    return;
  }
  // Documented thread-safe; unblocks glfwWaitEvents / glfwWaitEventsTimeout.
  glfwPostEmptyEvent();
}

bool Engine::renderFrame(uint32_t windowId)
{
  // Straight to the Application rather than through CanvasWindowHost: the host
  // only ever knew about one window, and a frame is per window.
  return impl_->withApp([&](Application &app) { return app.repaint(windowId); });
}

void Engine::beginFrameGroup()
{
  impl_->withApp([](Application &app) { app.beginFrameGroup(); });
}

void Engine::endFrameGroup()
{
  impl_->withApp([](Application &app) { app.endFrameGroup(); });
}

bool Engine::attachDrawArena(const std::string &id, uint32_t windowId)
{
  return impl_->withApp(
    [&](Application &app) { return app.attachDrawArena(id, windowId); });
}

void Engine::detachDrawArena(uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.detachDrawArena(windowId); });
}

uint32_t Engine::openWindow(uint32_t width, uint32_t height,
                            const std::string &title)
{
  return impl_->withApp([&](Application &app) {
    return app.openWindow(static_cast<int>(width), static_cast<int>(height),
                          title);
  });
}

void Engine::closeWindow(uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.closeWindow(windowId); });
}

size_t Engine::windowCount() const
{
  return impl_->withApp([](Application &app) { return app.windowCount(); });
}

uint32_t Engine::windowIdAt(size_t index) const
{
  return impl_->withApp([&](Application &app) { return app.windowIdAt(index); });
}

bool Engine::windowShouldClose(uint32_t windowId) const
{
  return impl_->withApp(
    [&](Application &app) { return app.windowShouldClose(windowId); });
}

bool Engine::takeInternalRepaint(uint32_t windowId)
{
  return impl_->withApp(
    [&](Application &app) { return app.takeInternalRepaint(windowId); });
}

bool Engine::scrollSceneUnclaimed(float dx, float dy, uint32_t windowId)
{
  return impl_->withApp([&](Application &app) {
    return app.scrollSceneUnclaimed(dx, dy, windowId);
  });
}

bool Engine::isOpen() const
{
  if (impl_->mode == Impl::Mode::Windowed)
    return impl_->window && impl_->window->isOpen();
  return (impl_->mode == Impl::Mode::Offscreen
          || impl_->mode == Impl::Mode::Client)
         && impl_->offscreen != nullptr;
}

void Engine::requestClose()
{
  impl_->withApp([&](Application &app) { app.requestClose(); });
}

void Engine::setWindowFrame(int x, int y, int width, int height, uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.setWindowFrame(x, y, width, height, windowId);
  });
}

void Engine::setWindowCornerRadius(float radius, bool top, bool bottom,
                                   uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.setWindowCornerRadius(radius, top, bottom, windowId);
  });
}

void Engine::setCursorShape(uint32_t shape, uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.setCursorShape(shape, windowId); });
}

void Engine::setWindowVisible(bool visible, uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.setWindowVisible(visible, windowId); });
  // Keep the host's own flag in step for the main window, which is what
  // `Engine::isOpen` and the legacy single-window path still read.
  if (windowId == 0 && impl_->window) impl_->window->setVisible(visible);
}

bool Engine::isWindowVisible(uint32_t windowId) const
{
  return impl_->withApp(
    [&](Application &app) { return !app.isIconified(windowId); });
}

bool Engine::repaint(uint32_t windowId)
{
  return impl_->withApp([&](Application &app) { return app.repaint(windowId); });
}

bool Engine::pollDrawArena(uint32_t windowId)
{
  return impl_->withApp(
    [&](Application &app) { return app.pollDrawArena(windowId); });
}

uint64_t Engine::frameCounter(uint32_t windowId) const
{
  return impl_->withApp(
    [&](Application &app) { return app.frameCounter(windowId); });
}

bool Engine::opaqueBounds(uint32_t windowId, float &x, float &y, float &w,
                          float &h) const
{
  return impl_->withApp(
    [&](Application &app) { return app.opaqueBounds(windowId, x, y, w, h); });
}

void Engine::readPixels(uint8_t *dst, size_t dstSize)
{
  impl_->withApp([&](Application &app) { app.readPixels(dst, dstSize); });
}

std::string Engine::capturePngBase64(int x, int y, int w, int h, int maxSide,
                                     int *outW, int *outH, uint32_t windowId)
{
  std::string out;
  impl_->withApp([&](Application &app) {
    out = app.capturePngBase64(x, y, w, h, maxSide, outW, outH, windowId);
  });
  return out;
}

U8Vector Engine::capturePng(int x, int y, int w, int h, int maxSide,
                            int *outW, int *outH, uint32_t windowId)
{
  U8Vector out;
  impl_->withApp([&](Application &app) {
    if (!app.capturePng(out, x, y, w, h, maxSide, outW, outH, windowId)) {
      out.clear();
    }
  });
  return out;
}

void Engine::pointerMove(float x, float y, uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.pointerMove(x, y, windowId); });
}

void Engine::pointerButton(int button, bool pressed, float x, float y, uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.pointerButton(button, pressed, x, y, windowId);
  });
}

void Engine::pointerScroll(float dx, float dy, uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.scroll(dx, dy, windowId); });
}

void Engine::keyEvent(int key, int action, int mods, uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.keyEvent(key, action, mods, windowId); });
}

void Engine::textInput(const std::string &utf8, uint32_t windowId)
{
  impl_->withApp([&](Application &app) { app.textInput(utf8, windowId); });
}

void Engine::submitDrawList(const DrawCommand *cmds, size_t cmdCount,
                            const GlyphInstance *glyphs, size_t glyphCount,
                            const MeshVertex *meshVerts, size_t meshVertCount,
                            const SpatialVertex *spatialVerts, size_t spatialVertCount,
                            uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.submitDrawList(cmds, cmdCount, glyphs, glyphCount, meshVerts, meshVertCount,
                       spatialVerts, spatialVertCount, windowId);
  });
}

void Engine::ensureDrawListCapacity(size_t cmdCapacity, size_t glyphCapacity,
                                    size_t meshVertCapacity, size_t spatialVertCapacity,
                                    size_t gradientCapacity, uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.ensureDrawListCapacity(cmdCapacity, glyphCapacity, meshVertCapacity,
                               spatialVertCapacity, gradientCapacity, windowId);
  });
}

DrawCommand *Engine::drawCommandData(uint32_t windowId)
{
  return impl_->withApp([&](Application &app) { return app.drawCommandData(windowId); });
}

GlyphInstance *Engine::drawGlyphData(uint32_t windowId)
{
  return impl_->withApp([&](Application &app) { return app.drawGlyphData(windowId); });
}

MeshVertex *Engine::drawMeshVertexData(uint32_t windowId)
{
  return impl_->withApp([&](Application &app) { return app.drawMeshVertexData(windowId); });
}

SpatialVertex *Engine::drawSpatialVertexData(uint32_t windowId)
{
  return impl_->withApp([&](Application &app) { return app.drawSpatialVertexData(windowId); });
}

size_t Engine::drawCommandCapacity(uint32_t windowId) const
{
  return const_cast<Engine *>(this)->impl_->withApp(
    [&](Application &app) { return app.drawCommandCapacity(windowId); });
}

size_t Engine::drawGlyphCapacity(uint32_t windowId) const
{
  return const_cast<Engine *>(this)->impl_->withApp(
    [&](Application &app) { return app.drawGlyphCapacity(windowId); });
}

size_t Engine::drawMeshVertexCapacity(uint32_t windowId) const
{
  return const_cast<Engine *>(this)->impl_->withApp(
    [&](Application &app) { return app.drawMeshVertexCapacity(windowId); });
}

size_t Engine::drawSpatialVertexCapacity(uint32_t windowId) const
{
  return const_cast<Engine *>(this)->impl_->withApp(
    [&](Application &app) { return app.drawSpatialVertexCapacity(windowId); });
}

GradientDesc *Engine::drawGradientData(uint32_t windowId)
{
  return impl_->withApp([&](Application &app) { return app.drawGradientData(windowId); });
}

size_t Engine::drawGradientCapacity(uint32_t windowId) const
{
  return impl_->withApp(
    [&](Application &app) { return app.drawGradientCapacity(windowId); });
}

void Engine::commitDrawList(size_t cmdCount, size_t glyphCount,
                            size_t meshVertCount, size_t spatialVertCount,
                            size_t gradientCount, uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.commitDrawList(cmdCount, glyphCount, meshVertCount, spatialVertCount,
                       gradientCount, windowId);
  });
}

bool Engine::pollInputEvent(InputEvent &out, uint32_t windowId)
{
  return impl_->withApp([&](Application &app) {
    return app.pollInputEvent(out, windowId);
  });
}

StringVector Engine::pendingDroppedFiles(uint32_t windowId)
{
  return impl_->withApp([&](Application &app) {
    StringVector out;
    const int n = app.pendingDroppedFileCount(windowId);
    out.reserve(static_cast<size_t>(n > 0 ? n : 0));
    for (int i = 0; i < n; ++i) {
      out.push_back(app.pendingDroppedFile(i, windowId));
    }
    return out;
  });
}

void Engine::framebufferSize(float &outW, float &outH, uint32_t windowId) const
{
  const_cast<Engine *>(this)->impl_->withApp([&](Application &app) {
    app.framebufferSize(outW, outH, windowId);
  });
}

void Engine::setViewTransform(float zoom, float panX, float panY, uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.setViewTransform(zoom, panX, panY, windowId);
  });
}

VoidResult Engine::loadFont(const std::string &path, float pixelSize)
{
  return impl_->withApp([&](Application &app) {
    return app.loadFont(path, pixelSize);
  });
}

std::string Engine::clipboardText() const
{
  std::string out;
  impl_->withApp([&](Application &app) { out = app.clipboardText(); });
  return out;
}

void Engine::setClipboardText(const std::string &text)
{
  impl_->withApp([&](Application &app) { app.setClipboardText(text); });
}

int Engine::registerFace(const std::string &path, uint32_t pixelSize26_6,
                         uint32_t faceIndex, uint32_t rasterFlags)
{
  int id = -1;
  impl_->withApp([&](Application &app) {
    id = app.registerFont(path, pixelSize26_6, faceIndex, rasterFlags);
  });
  return id;
}

int Engine::registerFont(const std::string &path, float pixelSize)
{
  return registerFace(path, canvas::pixelSizeTo26_6(pixelSize), 0,
                      canvas::RasterFlags::of(canvas::FontHinting::Normal));
}

int Engine::loadTexture(const std::string &path)
{
  int id = -1;
  impl_->withApp([&](Application &app) { id = app.loadTexture(path); });
  return id;
}

void Engine::unloadTexture(const std::string &path)
{
  impl_->withApp([&](Application &app) { app.unloadTexture(path); });
}

namespace {

/// Everything `decodeImage` does after stb has handed back RGBA8: the cap, the
/// sRGB-correct downscale, and taking ownership of the buffer.
///
/// Shared by the file and the memory entry points because the two differ in
/// exactly one call — which file to open versus which bytes to read — and
/// nothing after it. Takes ownership of `pixels` either way.
DecodedImage finishDecode(stbi_uc *pixels, int w, int h, uint32_t maxPixelSize)
{
  DecodedImage out;
  if (pixels == nullptr || w <= 0 || h <= 0) {
    if (pixels) stbi_image_free(pixels);
    return out;
  }

  auto adopt = [&](uint8_t *p, int ww, int hh) {
    const size_t n = static_cast<size_t>(ww) * static_cast<size_t>(hh) * 4;
    out.pixels.assign(p, p + n);
    out.width = static_cast<uint32_t>(ww);
    out.height = static_cast<uint32_t>(hh);
    stbi_image_free(p);
  };

  const uint32_t longEdge = static_cast<uint32_t>(w > h ? w : h);
  if (maxPixelSize > 0 && longEdge > maxPixelSize) {
    const double scale = static_cast<double>(maxPixelSize) / longEdge;
    // At least one pixel each way: a 1x1 destination is silly but a 0x0 one
    // fails the upload and loses the image entirely.
    int dw = static_cast<int>(w * scale + 0.5);
    int dh = static_cast<int>(h * scale + 0.5);
    if (dw < 1) dw = 1;
    if (dh < 1) dh = 1;

    // The texture format is R8G8B8A8_**SRGB**, so the filter has to average in
    // linear light. Resizing the encoded bytes directly darkens every
    // downscale — the classic sRGB resampling bug, and very visible on album
    // art. STBIR_RGBA (not _PM) because stb_image hands back straight,
    // non-premultiplied alpha.
    uint8_t *scaled = stbir_resize_uint8_srgb(
      pixels, w, h, 0, nullptr, dw, dh, 0, STBIR_RGBA);
    if (scaled != nullptr) {
      stbi_image_free(pixels);
      adopt(scaled, dw, dh);
      return out;
    }
    // Resize failed (allocation): fall through with the full-size decode
    // rather than dropping the image.
  }

  adopt(pixels, w, h);
  return out;
}

}  // namespace

DecodedImage Engine::decodeImage(const std::string &path, uint32_t maxPixelSize)
{
  // An SVG has no pixels to load, only a shape to draw — so `maxPixelSize` is
  // not a cap here but the size itself, and the result needs no downscale
  // afterwards. That is the whole reason icons are worth rendering rather than
  // unpacking: a 48-pixel PNG drawn at 64 is soft, and this is not.
  if (path.size() > 4 &&
      path.compare(path.size() - 4, 4, ".svg") == 0) {
    DecodedImage out;
    out.pixels = rasterizeSvg(path, maxPixelSize, out.width, out.height);
    if (out.pixels.empty()) return DecodedImage{};
    return out;
  }

  int w = 0, h = 0, channels = 0;
  // stbi_load is reentrant and touches no shared state, which is what makes
  // this callable off the device thread.
  stbi_uc *pixels = stbi_load(path.c_str(), &w, &h, &channels, 4);
  return finishDecode(pixels, w, h, maxPixelSize);
}

DecodedImage Engine::decodeImageData(const uint8_t *bytes, size_t byteCount,
                                     uint32_t maxPixelSize)
{
  if (bytes == nullptr || byteCount == 0) return DecodedImage{};
  int w = 0, h = 0, channels = 0;
  // Same decoder, same guarantees — stb does not care whether the bytes came
  // from a file, and neither does anything downstream of here. What differs is
  // upstream: these bytes came from another process, so the caller is the one
  // that has to decide whether to trust them. stb is the same code path an
  // untrusted *file* already went through, which is the honest baseline.
  stbi_uc *pixels = stbi_load_from_memory(
    bytes, static_cast<int>(byteCount), &w, &h, &channels, 4);
  return finishDecode(pixels, w, h, maxPixelSize);
}

DecodedImage Engine::encodeRgbaPng(const uint8_t *rgba, uint32_t width,
                                   uint32_t height, uint32_t maxSide)
{
  DecodedImage out;
  if (rgba == nullptr || width == 0 || height == 0) return out;
  int encW = 0, encH = 0;
  if (!::canvas::encodeRgbaPng(rgba, static_cast<int>(width),
                               static_cast<int>(height),
                               static_cast<int>(width) * 4,
                               static_cast<int>(maxSide), out.pixels, encW,
                               encH) ||
      out.pixels.empty()) {
    return DecodedImage{};
  }
  // Width/height are the encoded pixel size, not a claim that `pixels` is
  // RGBA — `copyTo` is what Swift uses, and it does not consult `valid()`.
  out.width = static_cast<uint32_t>(encW);
  out.height = static_cast<uint32_t>(encH);
  return out;
}

int Engine::uploadTexture(const std::string &key, const uint8_t *rgba,
                          uint32_t width, uint32_t height)
{
  int id = -1;
  impl_->withApp([&](Application &app) {
    id = app.uploadTexture(key, rgba, width, height);
  });
  return id;
}

int Engine::uploadTexture(const std::string &key, const U8Vector &rgba,
                          uint32_t width, uint32_t height)
{
  if (rgba.empty()) return -1;
  return uploadTexture(key, rgba.data(), width, height);
}

bool Engine::hasTexture(const std::string &key) const
{
  bool found = false;
  impl_->withApp([&](Application &app) { found = app.hasTexture(key); });
  return found;
}

int Engine::reviveTexture(const std::string &key, uint32_t &outWidth,
                          uint32_t &outHeight)
{
  int id = -1;
  impl_->withApp([&](Application &app) {
    id = app.reviveTexture(key, outWidth, outHeight);
  });
  return id;
}

bool Engine::textureSize(uint32_t textureId, float &outW, float &outH) const
{
  bool ok = false;
  const_cast<Engine *>(this)->impl_->withApp([&](Application &app) {
    ok = app.textureSize(textureId, outW, outH);
  });
  return ok;
}

Application *Engine::application() { return impl_->app(); }

uint32_t Engine::x11WindowId() const
{
  uint32_t id = 0;
  const_cast<Engine *>(this)->impl_->withApp([&](Application &app) {
    id = app.x11WindowId();
  });
  return id;
}

bool Engine::appMenuRegistrarAvailable()
{
  return AppMenuHost::registrarAvailable();
}

bool Engine::appMenuAttach()
{
  const uint32_t xid = x11WindowId();
  if (xid == 0) return false;
  return impl_->appMenu.attach(xid);
}

bool Engine::appMenuAttachWindow(uint32_t windowId)
{
  // The registrar's key is an X11 window id only because X11 is where the
  // protocol grew up; it is a `u` on the wire and nothing on the panel side
  // looks it up in an X server. A client of the lava compositor has no X11
  // id at all — its window is a surface id — so this is the same registration
  // keyed by the number that *does* name its window here, which is also the
  // number the compositor reports as focused.
  if (windowId == 0) return false;
  return impl_->appMenu.attach(windowId);
}

void Engine::appMenuDetach() { impl_->appMenu.detach(); }

bool Engine::appMenuIsAttached() const { return impl_->appMenu.isAttached(); }

void Engine::appMenuPoll() { impl_->appMenu.poll(); }

void Engine::appMenuBeginUpdate() { impl_->appMenu.beginUpdate(); }

void Engine::appMenuBeginMenu(const std::string &id, const std::string &title)
{
  impl_->appMenu.beginMenu(id, title);
}

void Engine::appMenuEndMenu() { impl_->appMenu.endMenu(); }

void Engine::appMenuAddItem(const std::string &id, const std::string &title,
                            bool enabled, int checked)
{
  impl_->appMenu.addItem(id, title, enabled, checked);
}

void Engine::appMenuAddSeparator() { impl_->appMenu.addSeparator(); }

void Engine::appMenuCommitUpdate() { impl_->appMenu.commitUpdate(); }

std::string Engine::appMenuPopActivation()
{
  std::string id;
  if (impl_->appMenu.popActivation(id)) return id;
  return {};
}

// ─── Menu import (the panel side) ─────────────────────────────────────────

bool Engine::menuImportStart() { return impl_->menuImport.start(); }

std::string Engine::menuImportBusName() { return impl_->menuImport.busName(); }

void Engine::menuImportSetActiveWindow(uint32_t windowId,
                                       std::string menuService,
                                       std::string menuObjectPath)
{
  impl_->menuImport.setActiveWindow(windowId, std::move(menuService),
                                    std::move(menuObjectPath));
}

void Engine::menuImportPoll() { impl_->menuImport.poll(); }

uint64_t Engine::menuImportRevision() const
{
  return impl_->menuImport.revision();
}

size_t Engine::menuImportItemCount() const
{
  return impl_->menuImport.itemCount();
}

int32_t Engine::menuImportItemId(size_t index) const
{
  return impl_->menuImport.itemId(index);
}

int32_t Engine::menuImportItemParent(size_t index) const
{
  return impl_->menuImport.itemParent(index);
}

std::string Engine::menuImportItemLabel(size_t index) const
{
  return impl_->menuImport.itemLabel(index);
}

bool Engine::menuImportItemEnabled(size_t index) const
{
  return impl_->menuImport.itemEnabled(index);
}

bool Engine::menuImportItemSeparator(size_t index) const
{
  return impl_->menuImport.itemSeparator(index);
}

bool Engine::menuImportItemHasSubmenu(size_t index) const
{
  return impl_->menuImport.itemHasSubmenu(index);
}

int Engine::menuImportItemChecked(size_t index) const
{
  return impl_->menuImport.itemChecked(index);
}

void Engine::menuImportActivate(int32_t itemId)
{
  impl_->menuImport.activate(itemId);
}

void Engine::menuImportAboutToShow(int32_t itemId)
{
  impl_->menuImport.aboutToShow(itemId);
}

// ─── Status Notifier (system tray) ────────────────────────────────────────

bool Engine::statusNotifierStart() { return impl_->statusNotifier.start(); }

bool Engine::statusNotifierIsServing() const
{
  return impl_->statusNotifier.isServing();
}

void Engine::statusNotifierPoll() { impl_->statusNotifier.poll(); }

uint64_t Engine::statusNotifierRevision() const
{
  return impl_->statusNotifier.revision();
}

size_t Engine::statusNotifierItemCount() const
{
  return impl_->statusNotifier.itemCount();
}

std::string Engine::statusNotifierItemKey(size_t index) const
{
  return impl_->statusNotifier.itemKey(index);
}

std::string Engine::statusNotifierItemId(size_t index) const
{
  return impl_->statusNotifier.itemId(index);
}

std::string Engine::statusNotifierItemTitle(size_t index) const
{
  return impl_->statusNotifier.itemTitle(index);
}

std::string Engine::statusNotifierItemStatus(size_t index) const
{
  return impl_->statusNotifier.itemStatus(index);
}

std::string Engine::statusNotifierItemIconName(size_t index) const
{
  return impl_->statusNotifier.itemIconName(index);
}

std::string Engine::statusNotifierItemIconPath(size_t index) const
{
  return impl_->statusNotifier.itemIconPath(index);
}

bool Engine::statusNotifierItemIsMenu(size_t index) const
{
  return impl_->statusNotifier.itemIsMenu(index);
}

int Engine::statusNotifierItemIconWidth(size_t index) const
{
  return impl_->statusNotifier.itemIconWidth(index);
}

int Engine::statusNotifierItemIconHeight(size_t index) const
{
  return impl_->statusNotifier.itemIconHeight(index);
}

size_t Engine::statusNotifierItemIconRgbaSize(size_t index) const
{
  return impl_->statusNotifier.itemIconRgbaSize(index);
}

size_t Engine::statusNotifierItemIconRgbaCopy(size_t index, uint8_t *out,
                                              size_t cap) const
{
  return impl_->statusNotifier.itemIconRgbaCopy(index, out, cap);
}

void Engine::statusNotifierActivate(const std::string &key, int x, int y)
{
  impl_->statusNotifier.activate(key, x, y);
}

void Engine::statusNotifierContextMenu(const std::string &key, int x, int y)
{
  impl_->statusNotifier.contextMenu(key, x, y);
}

void Engine::statusNotifierSecondaryActivate(const std::string &key, int x,
                                             int y)
{
  impl_->statusNotifier.secondaryActivate(key, x, y);
}

void Engine::statusNotifierScroll(const std::string &key, int delta,
                                  const std::string &orientation)
{
  impl_->statusNotifier.scroll(key, delta, orientation);
}

bool Engine::statusNotifierItemHasMenu(size_t index) const
{
  return impl_->statusNotifier.itemHasMenu(index);
}

bool Engine::statusNotifierItemPrefersMenu(size_t index) const
{
  return impl_->statusNotifier.itemPrefersMenu(index);
}

bool Engine::statusNotifierOpenMenu(const std::string &key)
{
  return impl_->statusNotifier.openMenu(key);
}

void Engine::statusNotifierCloseMenu()
{
  impl_->statusNotifier.closeMenu();
}

uint64_t Engine::statusNotifierMenuRevision() const
{
  return impl_->statusNotifier.menuRevision();
}

size_t Engine::statusNotifierMenuItemCount() const
{
  return impl_->statusNotifier.menuItemCount();
}

int32_t Engine::statusNotifierMenuItemId(size_t index) const
{
  return impl_->statusNotifier.menuItemId(index);
}

int32_t Engine::statusNotifierMenuItemParent(size_t index) const
{
  return impl_->statusNotifier.menuItemParent(index);
}

std::string Engine::statusNotifierMenuItemLabel(size_t index) const
{
  return impl_->statusNotifier.menuItemLabel(index);
}

bool Engine::statusNotifierMenuItemEnabled(size_t index) const
{
  return impl_->statusNotifier.menuItemEnabled(index);
}

bool Engine::statusNotifierMenuItemSeparator(size_t index) const
{
  return impl_->statusNotifier.menuItemSeparator(index);
}

bool Engine::statusNotifierMenuItemHasSubmenu(size_t index) const
{
  return impl_->statusNotifier.menuItemHasSubmenu(index);
}

int Engine::statusNotifierMenuItemChecked(size_t index) const
{
  return impl_->statusNotifier.menuItemChecked(index);
}

void Engine::statusNotifierMenuActivate(int32_t itemId)
{
  impl_->statusNotifier.menuActivate(itemId);
}

void Engine::statusNotifierMenuAboutToShow(int32_t itemId)
{
  impl_->statusNotifier.menuAboutToShow(itemId);
}


// ─── Notifications ─────────────────────────────────────────────────────────

bool Engine::notificationsStart() { return impl_->notifications.start(); }

bool Engine::notificationsIsServing() const
{
  return impl_->notifications.isServing();
}

void Engine::notificationsPoll() { impl_->notifications.poll(); }

uint64_t Engine::notificationsRevision() const
{
  return impl_->notifications.revision();
}

size_t Engine::notificationsCount() const
{
  return impl_->notifications.count();
}

uint32_t Engine::notificationId(size_t index) const
{
  return impl_->notifications.id(index);
}

std::string Engine::notificationAppName(size_t index) const
{
  return impl_->notifications.appName(index);
}

std::string Engine::notificationSummary(size_t index) const
{
  return impl_->notifications.summary(index);
}

std::string Engine::notificationBody(size_t index) const
{
  return impl_->notifications.body(index);
}

std::string Engine::notificationIconPath(size_t index) const
{
  return impl_->notifications.iconPath(index);
}

int Engine::notificationIconWidth(size_t index) const
{
  return impl_->notifications.iconWidth(index);
}

int Engine::notificationIconHeight(size_t index) const
{
  return impl_->notifications.iconHeight(index);
}

size_t Engine::notificationIconRgbaSize(size_t index) const
{
  return impl_->notifications.iconRgbaSize(index);
}

size_t Engine::notificationIconRgbaCopy(size_t index, uint8_t *out,
                                        size_t cap) const
{
  return impl_->notifications.iconRgbaCopy(index, out, cap);
}

uint8_t Engine::notificationUrgency(size_t index) const
{
  return impl_->notifications.urgency(index);
}

int64_t Engine::notificationRemainingMs(size_t index) const
{
  return impl_->notifications.remainingMs(index);
}

size_t Engine::notificationActionCount(size_t index) const
{
  return impl_->notifications.actionCount(index);
}

std::string Engine::notificationActionKey(size_t index, size_t action) const
{
  return impl_->notifications.actionKey(index, action);
}

std::string Engine::notificationActionLabel(size_t index, size_t action) const
{
  return impl_->notifications.actionLabel(index, action);
}

void Engine::notificationInvokeAction(uint32_t id, const std::string &key)
{
  impl_->notifications.invokeAction(id, key);
}

void Engine::notificationDismiss(uint32_t id)
{
  impl_->notifications.dismiss(id);
}

void Engine::notificationDismissAll() { impl_->notifications.dismissAll(); }

void Engine::notificationsSetPaused(bool paused)
{
  impl_->notifications.setPaused(paused);
}

} // namespace canvas
