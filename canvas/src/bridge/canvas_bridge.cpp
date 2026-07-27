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

int CanvasBridge::addRect(float x, float y, float width, float height,
                           float r, float g, float b, float a) noexcept
{
  try {
    return impl_->app.addRect(x, y, width, height, r, g, b, a);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::addRect: " << ex.what() << '\n';
    return -1;
  } catch (...) {
    std::cerr << "CanvasBridge::addRect: unknown exception\n";
    return -1;
  }
}

void CanvasBridge::updateRect(int id, float x, float y, float width, float height,
                               float r, float g, float b, float a) noexcept
{
  try {
    impl_->app.updateRect(id, x, y, width, height, r, g, b, a);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::updateRect: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::updateRect: unknown exception\n";
  }
}

int CanvasBridge::addRoundedRect(float x, float y, float width, float height,
                                   float r, float g, float b, float a) noexcept
{
  try {
    return impl_->app.addRoundedRect(x, y, width, height, r, g, b, a);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::addRoundedRect: " << ex.what() << '\n';
    return -1;
  } catch (...) {
    std::cerr << "CanvasBridge::addRoundedRect: unknown exception\n";
    return -1;
  }
}

int CanvasBridge::addCircle(float centerX, float centerY, float radius,
                              float r, float g, float b, float a) noexcept
{
  try {
    return impl_->app.addCircle(centerX, centerY, radius, r, g, b, a);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::addCircle: " << ex.what() << '\n';
    return -1;
  } catch (...) {
    std::cerr << "CanvasBridge::addCircle: unknown exception\n";
    return -1;
  }
}

void CanvasBridge::removeShape(int id) noexcept
{
  try {
    impl_->app.removeShape(id);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::removeShape: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::removeShape: unknown exception\n";
  }
}

void CanvasBridge::clearShapes() noexcept
{
  try {
    impl_->app.clearShapes();
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::clearShapes: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::clearShapes: unknown exception\n";
  }
}

int CanvasBridge::addLine(float x1, float y1, float x2, float y2,
                            float r, float g, float b, float a) noexcept
{
  try {
    return impl_->app.addLine(x1, y1, x2, y2, r, g, b, a);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::addLine: " << ex.what() << '\n';
    return -1;
  } catch (...) {
    std::cerr << "CanvasBridge::addLine: unknown exception\n";
    return -1;
  }
}

void CanvasBridge::removeLine(int id) noexcept
{
  try {
    impl_->app.removeLine(id);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::removeLine: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::removeLine: unknown exception\n";
  }
}

void CanvasBridge::clearLines() noexcept
{
  try {
    impl_->app.clearLines();
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::clearLines: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::clearLines: unknown exception\n";
  }
}

int CanvasBridge::addLabel(const std::string &text, float x, float y,
                             float r, float g, float b) noexcept
{
  try {
    return impl_->app.addLabel(text, x, y, r, g, b);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::addLabel: " << ex.what() << '\n';
    return -1;
  } catch (...) {
    std::cerr << "CanvasBridge::addLabel: unknown exception\n";
    return -1;
  }
}

void CanvasBridge::removeLabel(int id) noexcept
{
  try {
    impl_->app.removeLabel(id);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::removeLabel: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::removeLabel: unknown exception\n";
  }
}

void CanvasBridge::clearLabels() noexcept
{
  try {
    impl_->app.clearLabels();
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::clearLabels: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::clearLabels: unknown exception\n";
  }
}

int CanvasBridge::addTextWidget(float x, float y, float width, float height,
                                const std::string &text, bool multiline) noexcept
{
  try {
    return impl_->app.addTextWidget(x, y, width, height, text, multiline);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::addTextWidget: " << ex.what() << '\n';
    return -1;
  } catch (...) {
    std::cerr << "CanvasBridge::addTextWidget: unknown exception\n";
    return -1;
  }
}

void CanvasBridge::setTextWidgetRect(int id, float x, float y, float width, float height) noexcept
{
  try {
    impl_->app.setTextWidgetRect(id, x, y, width, height);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::setTextWidgetRect: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::setTextWidgetRect: unknown exception\n";
  }
}

void CanvasBridge::setTextWidgetText(int id, const std::string &text) noexcept
{
  try {
    impl_->app.setTextWidgetText(id, text);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::setTextWidgetText: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::setTextWidgetText: unknown exception\n";
  }
}

std::string CanvasBridge::getTextWidgetText(int id) noexcept
{
  try {
    return impl_->app.getTextWidgetText(id);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::getTextWidgetText: " << ex.what() << '\n';
    return {};
  } catch (...) {
    std::cerr << "CanvasBridge::getTextWidgetText: unknown exception\n";
    return {};
  }
}

bool CanvasBridge::setTextWidgetHighlightRules(
  int id, const std::vector<TextHighlightRule> &rules) noexcept
{
  try {
    return impl_->app.setTextWidgetHighlightRules(id, rules);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::setTextWidgetHighlightRules: " << ex.what() << '\n';
    return false;
  } catch (...) {
    std::cerr << "CanvasBridge::setTextWidgetHighlightRules: unknown exception\n";
    return false;
  }
}

void CanvasBridge::setTextWidgetFocused(int id, bool focused) noexcept
{
  try {
    impl_->app.setTextWidgetFocused(id, focused);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::setTextWidgetFocused: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::setTextWidgetFocused: unknown exception\n";
  }
}

bool CanvasBridge::isTextWidgetFocused(int id) noexcept
{
  try {
    return impl_->app.isTextWidgetFocused(id);
  } catch (...) {
    return false;
  }
}

bool CanvasBridge::textWidgetChanged(int id) noexcept
{
  try {
    return impl_->app.textWidgetChanged(id);
  } catch (...) {
    return false;
  }
}

void CanvasBridge::removeTextWidget(int id) noexcept
{
  try {
    impl_->app.removeTextWidget(id);
  } catch (const std::exception &ex) {
    std::cerr << "CanvasBridge::removeTextWidget: " << ex.what() << '\n';
  } catch (...) {
    std::cerr << "CanvasBridge::removeTextWidget: unknown exception\n";
  }
}

bool CanvasBridge::wantsAnimation() noexcept
{
  try {
    return impl_->app.wantsAnimation();
  } catch (...) {
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
