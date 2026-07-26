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
  impl_->app.init(assetsRoot);
}

CanvasBridge::CanvasBridge(CanvasBridge &&) noexcept = default;
CanvasBridge &CanvasBridge::operator=(CanvasBridge &&) noexcept = default;

CanvasBridge::~CanvasBridge()
{
  if (impl_) {
    impl_->app.shutdown();
  }
}

bool CanvasBridge::tick(double deltaTimeSeconds) noexcept
{
  try {
    return impl_->app.tick(static_cast<float>(deltaTimeSeconds));
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::tick: " << ex.what() << '\n';
    return false;
  } catch (...) {
    std::cerr << "CanvasBridge::tick: unknown exception\n";
    return false;
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
