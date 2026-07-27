#include "bridge/canvas_engine.hpp"

#include "application.hpp"
#include "render/text_widget.hpp"
#include "window/canvas_window.hpp"

#include <mutex>
#include <type_traits>

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
      std::lock_guard lock(window->mutex());
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

void Engine::setProjectTree(std::vector<TreeItem> items)
{
  impl_->withApp([&](Application &app) { app.setProjectTree(std::move(items)); });
}

void Engine::setProperties(std::vector<PropertyItem> items)
{
  impl_->withApp([&](Application &app) { app.setProperties(std::move(items)); });
}

std::string Engine::selectedTreeId() const
{
  // const_cast for withApp non-const Application API
  return const_cast<Engine *>(this)->impl_->withApp(
    [](Application &app) { return app.selectedTreeId(); });
}

void Engine::setWorkspaceLayout(shell::Node root)
{
  impl_->withApp([&](Application &app) {
    app.setWorkspaceLayout(std::move(root));
  });
}

void Engine::setWorkspaceColumns(shell::PanelKind left, shell::PanelKind center,
                                 shell::PanelKind right,
                                 float leftWidth, float rightWidth)
{
  impl_->withApp([&](Application &app) {
    app.setWorkspaceColumns(left, center, right, leftWidth, rightWidth);
  });
}

void Engine::uiReset()
{
  impl_->withApp([](Application &app) { app.uiReset(); });
}

void Engine::uiBegin(int kind, int id, float flexGrow, float flexShrink,
                     float width, float height, float padding)
{
  impl_->withApp([&](Application &app) {
    app.uiBegin(kind, id, flexGrow, flexShrink, width, height, padding);
  });
}

void Engine::uiText(int id, const char *text, float r, float g, float b,
                    bool clickable)
{
  impl_->withApp([&](Application &app) {
    app.uiText(id, text, r, g, b, clickable);
  });
}

void Engine::uiEnd()
{
  impl_->withApp([](Application &app) { app.uiEnd(); });
}

void Engine::uiCommit()
{
  impl_->withApp([](Application &app) { app.uiCommit(); });
}

bool Engine::uiPollEvent(int &outWidgetId, int &outKind)
{
  return impl_->withApp([&](Application &app) {
    return app.uiPollEvent(outWidgetId, outKind);
  });
}

int Engine::addRect(float x, float y, float w, float h,
                    float r, float g, float b, float a)
{
  return impl_->withApp([&](Application &app) {
    return app.addRect(x, y, w, h, r, g, b, a);
  });
}

void Engine::updateRect(int id, float x, float y, float w, float h,
                        float r, float g, float b, float a)
{
  impl_->withApp([&](Application &app) {
    app.updateRect(id, x, y, w, h, r, g, b, a);
  });
}

int Engine::addRoundedRect(float x, float y, float w, float h,
                           float r, float g, float b, float a)
{
  return impl_->withApp([&](Application &app) {
    return app.addRoundedRect(x, y, w, h, r, g, b, a);
  });
}

int Engine::addCircle(float cx, float cy, float radius,
                      float r, float g, float b, float a)
{
  return impl_->withApp([&](Application &app) {
    return app.addCircle(cx, cy, radius, r, g, b, a);
  });
}

void Engine::removeShape(int id)
{
  impl_->withApp([&](Application &app) { app.removeShape(id); });
}

void Engine::clearShapes()
{
  impl_->withApp([&](Application &app) { app.clearShapes(); });
}

int Engine::addLine(float x1, float y1, float x2, float y2,
                    float r, float g, float b, float a)
{
  return impl_->withApp([&](Application &app) {
    return app.addLine(x1, y1, x2, y2, r, g, b, a);
  });
}

void Engine::removeLine(int id)
{
  impl_->withApp([&](Application &app) { app.removeLine(id); });
}

void Engine::clearLines()
{
  impl_->withApp([&](Application &app) { app.clearLines(); });
}

int Engine::addLabel(const std::string &text, float x, float y,
                     float r, float g, float b)
{
  return impl_->withApp([&](Application &app) {
    return app.addLabel(text, x, y, r, g, b);
  });
}

void Engine::removeLabel(int id)
{
  impl_->withApp([&](Application &app) { app.removeLabel(id); });
}

void Engine::clearLabels()
{
  impl_->withApp([&](Application &app) { app.clearLabels(); });
}

int Engine::addTextWidget(float x, float y, float w, float h,
                          const std::string &text, bool multiline)
{
  return impl_->withApp([&](Application &app) {
    return app.addTextWidget(x, y, w, h, text, multiline);
  });
}

void Engine::setTextWidgetText(int id, const std::string &text)
{
  impl_->withApp([&](Application &app) { app.setTextWidgetText(id, text); });
}

std::string Engine::textWidgetText(int id) const
{
  return const_cast<Engine *>(this)->impl_->withApp(
    [&](Application &app) { return app.getTextWidgetText(id); });
}

bool Engine::setTextWidgetHighlightRules(
  int id, const std::vector<TextHighlightRule> &rules)
{
  return impl_->withApp([&](Application &app) {
    return app.setTextWidgetHighlightRules(id, rules);
  });
}

void Engine::setTextWidgetFocused(int id, bool focused)
{
  impl_->withApp([&](Application &app) { app.setTextWidgetFocused(id, focused); });
}

bool Engine::textWidgetChanged(int id)
{
  return impl_->withApp([&](Application &app) { return app.textWidgetChanged(id); });
}

bool Engine::repaint()
{
  return impl_->withApp([](Application &app) { return app.repaint(); });
}

void Engine::readPixels(uint8_t *dst, size_t dstSize)
{
  impl_->withApp([&](Application &app) { app.readPixels(dst, dstSize); });
}

shell::Rect Engine::diagramViewport() const
{
  return const_cast<Engine *>(this)->impl_->withApp(
    [](Application &app) { return app.diagramViewport(); });
}

Application *Engine::application() { return impl_->app(); }

} // namespace canvas
