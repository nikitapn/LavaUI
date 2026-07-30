#include "bridge/canvas_engine.hpp"

#include "application.hpp"
#include "window/canvas_window.hpp"

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

#include <mutex>
#include <type_traits>
#include <unordered_map>

namespace canvas {

struct Engine::Impl {
  enum class Mode { None, Offscreen, Windowed } mode = Mode::None;
  std::unique_ptr<Application> offscreen;
  std::unique_ptr<CanvasWindowHost> window;

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

void Engine::close()
{
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
  if (impl_->window) impl_->window->pumpEvents(timeoutSeconds);
}

void Engine::wakeEventLoop()
{
  // Documented thread-safe; unblocks glfwWaitEvents / glfwWaitEventsTimeout.
  glfwPostEmptyEvent();
}

bool Engine::renderFrame()
{
  return impl_->window ? impl_->window->renderFrame() : false;
}

bool Engine::isOpen() const
{
  if (impl_->mode == Impl::Mode::Windowed)
    return impl_->window && impl_->window->isOpen();
  return impl_->mode == Impl::Mode::Offscreen && impl_->offscreen != nullptr;
}

void Engine::setWindowFrame(int x, int y, int width, int height)
{
  if (impl_->window) impl_->window->setFrame(x, y, width, height);
}

void Engine::setWindowVisible(bool visible)
{
  if (impl_->window) impl_->window->setVisible(visible);
}

bool Engine::isWindowVisible() const
{
  return impl_->window ? impl_->window->isVisible() : false;
}

bool Engine::repaint()
{
  return impl_->withApp([](Application &app) { return app.repaint(); });
}

void Engine::readPixels(uint8_t *dst, size_t dstSize)
{
  impl_->withApp([&](Application &app) { app.readPixels(dst, dstSize); });
}

std::string Engine::capturePngBase64(int x, int y, int w, int h, int maxSide,
                                     int *outW, int *outH)
{
  std::string out;
  impl_->withApp([&](Application &app) {
    out = app.capturePngBase64(x, y, w, h, maxSide, outW, outH);
  });
  return out;
}

void Engine::pointerMove(float x, float y)
{
  impl_->withApp([&](Application &app) { app.pointerMove(x, y); });
}

void Engine::pointerButton(int button, bool pressed, float x, float y)
{
  impl_->withApp([&](Application &app) {
    app.pointerButton(button, pressed, x, y);
  });
}

void Engine::keyEvent(int key, int action, int mods)
{
  impl_->withApp([&](Application &app) { app.keyEvent(key, action, mods); });
}

void Engine::textInput(const std::string &utf8)
{
  impl_->withApp([&](Application &app) { app.textInput(utf8); });
}

void Engine::submitDrawList(const DrawCommand *cmds, size_t cmdCount,
                            const GlyphInstance *glyphs, size_t glyphCount)
{
  impl_->withApp([&](Application &app) {
    app.submitDrawList(cmds, cmdCount, glyphs, glyphCount);
  });
}

bool Engine::pollInputEvent(InputEvent &out)
{
  return impl_->withApp([&](Application &app) {
    return app.pollInputEvent(out);
  });
}

void Engine::framebufferSize(float &outW, float &outH) const
{
  const_cast<Engine *>(this)->impl_->withApp([&](Application &app) {
    app.framebufferSize(outW, outH);
  });
}

void Engine::setViewTransform(float zoom, float panX, float panY)
{
  impl_->withApp([&](Application &app) {
    app.setViewTransform(zoom, panX, panY);
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

bool Engine::textureSize(uint32_t textureId, float &outW, float &outH) const
{
  bool ok = false;
  const_cast<Engine *>(this)->impl_->withApp([&](Application &app) {
    ok = app.textureSize(textureId, outW, outH);
  });
  return ok;
}

Application *Engine::application() { return impl_->app(); }

} // namespace canvas
