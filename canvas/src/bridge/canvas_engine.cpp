#include "bridge/canvas_engine.hpp"

#include <stb_image.h>
#include <stb_image_resize2.h>

#include "application.hpp"
#include "menu/app_menu.hpp"
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
      // No lock: the window host is caller-driven and single-threaded now,
      // so there is nothing to serialise against. This lock used to be held
      // by the render thread across a whole vsync-blocked frame, which cost
      // every call here ~17ms median and up to 200ms.
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
                                    uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.ensureDrawListCapacity(cmdCapacity, glyphCapacity, meshVertCapacity,
                               spatialVertCapacity, windowId);
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

void Engine::commitDrawList(size_t cmdCount, size_t glyphCount,
                            size_t meshVertCount, size_t spatialVertCount,
                            uint32_t windowId)
{
  impl_->withApp([&](Application &app) {
    app.commitDrawList(cmdCount, glyphCount, meshVertCount, spatialVertCount,
                       windowId);
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

int Engine::registerFont(const std::string &path, float pixelSize)
{
  int id = -1;
  impl_->withApp([&](Application &app) { id = app.registerFont(path, pixelSize); });
  return id;
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

} // namespace canvas
