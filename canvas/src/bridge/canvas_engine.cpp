#include "bridge/canvas_engine.hpp"

#include "application.hpp"
#include "render/text_widget.hpp"
#include "window/canvas_window.hpp"

#include <mutex>
#include <type_traits>
#include <unordered_map>

namespace canvas {

struct Engine::Impl {
  enum class Mode { None, Offscreen, Windowed } mode = Mode::None;
  std::unique_ptr<Application> offscreen;
  std::unique_ptr<CanvasWindowHost> window;

  // Staging buffers for the incremental builders below — exist purely so
  // Swift (which as of this toolchain can't construct std::vector<T>
  // itself; see the note on Editor.swift) can build these up one call at a
  // time instead of handing over a whole std::vector.
  std::vector<TreeItem> pendingTree;
  std::vector<PropertyItem> pendingProperties;
  std::unordered_map<int, std::vector<TextHighlightRule>> highlightRules;

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

void Engine::clearProjectTreeBuilder() { impl_->pendingTree.clear(); }

void Engine::addTreeItem(const std::string &id, const std::string &label,
                         int depth, bool selected)
{
  impl_->pendingTree.push_back(TreeItem{id, label, depth, selected});
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

void Engine::setDiagramViewport(float x, float y, float w, float h)
{
  impl_->withApp([&](Application &app) {
    app.setDiagramViewport(x, y, w, h);
  });
}

VoidResult Engine::loadFont(const std::string &path, float pixelSize)
{
  return impl_->withApp([&](Application &app) {
    return app.loadFont(path, pixelSize);
  });
}

int Engine::registerFont(const std::string &path, float pixelSize)
{
  int id = -1;
  impl_->withApp([&](Application &app) { id = app.registerFont(path, pixelSize); });
  return id;
}

Application *Engine::application() { return impl_->app(); }

} // namespace canvas
