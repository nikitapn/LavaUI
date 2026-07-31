#include "window/canvas_window.hpp"

#include "application.hpp"

#include <iostream>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

CanvasWindowHost::CanvasWindowHost() = default;

CanvasWindowHost::~CanvasWindowHost() {
  close();
}

bool CanvasWindowHost::open(const std::string& assetsRoot, uint32_t width,
                            uint32_t height, const std::string& title)
{
  if (open_) {
    std::cerr << "CanvasWindowHost::open: already open\n";
    return false;
  }

  app_ = std::make_unique<Application>(static_cast<int>(width),
                                       static_cast<int>(height));
  if (auto r = app_->initWithWindow(assetsRoot, title); !r) {
    std::cerr << "CanvasWindowHost: init failed: " << r.error() << '\n';
    app_.reset();
    return false;
  }

  // Single-window app: show immediately. Calling GLFW directly is fine now
  // that there is no second thread to race with, so the pendingFrame_ /
  // pendingVisible_ deferral this class used to need is gone.
  app_->setWindowVisible(true);
  visible_ = true;
  open_ = true;

  std::cout << "Canvas window open: " << width << "x" << height
            << " \"" << title << "\"\n";
  return true;
}

void CanvasWindowHost::close()
{
  if (app_) {
    app_->shutdown();
    app_.reset();
  }
  open_ = false;
}

bool CanvasWindowHost::isOpen() const
{
  if (!open_ || !app_) return false;
  return !app_->windowShouldClose();
}

void CanvasWindowHost::pumpEvents(double timeout)
{
  if (!app_) return;
  if (timeout < 0) {
    glfwWaitEvents();
  } else if (timeout == 0) {
    glfwPollEvents();
  } else {
    glfwWaitEventsTimeout(timeout);
  }
}

bool CanvasWindowHost::renderFrame()
{
  if (!app_ || !open_) return false;
  if (!visible_) return true;  // nothing to present while hidden
  return app_->repaint();
}

void CanvasWindowHost::setFrame(int x, int y, int width, int height)
{
  if (app_) app_->setWindowFrame(x, y, width, height);
}

void CanvasWindowHost::setVisible(bool visible)
{
  visible_ = visible;
  if (app_) app_->setWindowVisible(visible);
}

bool CanvasWindowHost::isVisible() const
{
  return visible_ && (!app_ || !app_->isIconified());
}
