#include "canvas_bridge.hpp"

#include "application.hpp"

#include <filesystem>
#include <iostream>

struct CanvasBridge::Impl {
  Application app;

  Impl(uint32_t width, uint32_t height)
    : app(static_cast<int>(width), static_cast<int>(height))
  {
  }
};

CanvasBridge::CanvasBridge(
  const std::string &assetsRoot, uint32_t width, uint32_t height)
{
  // Must happen before Impl (and therefore Application) is constructed:
  // Application's constructor builds a TextRenderer that loads a font via a
  // path relative to the current directory, before Application::init() (the
  // thing that used to set this) ever runs. This bit us in practice — it
  // only "worked" in the standalone canvas_test executable because that
  // happened to already be launched from the right directory by
  // coincidence, and broke the moment this got embedded in a process
  // launched from somewhere else (Swift/GTK).
  if (!assetsRoot.empty()) {
    std::filesystem::current_path(assetsRoot);
  }

  impl_ = std::make_unique<Impl>(width, height);
  if (auto r = impl_->app.init(assetsRoot); !r) {
    // Constructor cannot return Result — log and leave engine unusable.
    // Callers that care should use canvas_create_window / check create result.
    // For the C API, we throw only here so canvas_create can return NULL
    // (kept until create is refactored to a factory Result).
    throw std::runtime_error(r.error());
  }
}

CanvasBridge::CanvasBridge(CanvasBridge &&) noexcept = default;
CanvasBridge &CanvasBridge::operator=(CanvasBridge &&) noexcept = default;

CanvasBridge::~CanvasBridge()
{
  if (impl_) {
    impl_->app.shutdown();
  }
}

bool CanvasBridge::repaint() noexcept
{
  try {
    return impl_->app.repaint();
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::repaint: " << ex.what() << '\n';
    return false;
  } catch (...) {
    std::cerr << "CanvasBridge::repaint: unknown exception\n";
    return false;
  }
}

void CanvasBridge::pointerMove(float x, float y) noexcept
{
  try {
    impl_->app.pointerMove(x, y);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::pointerMove: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::pointerMove: unknown exception\n";
  }
}

void CanvasBridge::pointerButton(int button, bool pressed, float x, float y) noexcept
{
  try {
    impl_->app.pointerButton(button, pressed, x, y);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::pointerButton: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::pointerButton: unknown exception\n";
  }
}

void CanvasBridge::keyEvent(int key, int action, int mods) noexcept
{
  try {
    impl_->app.keyEvent(key, action, mods);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::keyEvent: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::keyEvent: unknown exception\n";
  }
}

void CanvasBridge::textInput(const std::string &utf8) noexcept
{
  try {
    impl_->app.textInput(utf8);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::textInput: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::textInput: unknown exception\n";
  }
}

void CanvasBridge::readPixels(uint8_t *dst, size_t dstSize) noexcept
{
  try {
    impl_->app.readPixels(dst, dstSize);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::readPixels: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::readPixels: unknown exception\n";
  }
}

Application &CanvasBridge::rawApp() noexcept
{
  return impl_->app;
}
