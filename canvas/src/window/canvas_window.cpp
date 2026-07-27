#include "window/canvas_window.hpp"

#include "application.hpp"

#include <chrono>
#include <iostream>
#include <thread>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

CanvasWindowHost::CanvasWindowHost() = default;

CanvasWindowHost::~CanvasWindowHost() {
  close();
}

bool CanvasWindowHost::open(const std::string& assetsRoot, uint32_t width,
                            uint32_t height, const std::string& title)
{
  if (running_.load()) {
    std::cerr << "CanvasWindowHost::open: already open\n";
    return false;
  }

  stopRequested_ = false;
  wantVisible_ = true;
  {
    std::lock_guard lock(mutex_);
    pendingFrame_.reset();
    pendingVisible_.reset();
  }

  thread_ = std::thread([this, assetsRoot, width, height, title]() {
    renderLoop(assetsRoot, width, height, title);
  });

  for (int i = 0; i < 200; ++i) {
    if (running_.load(std::memory_order_acquire)) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (!thread_.joinable()) return false;
  }
  if (!running_.load()) {
    if (thread_.joinable()) thread_.join();
    return false;
  }
  return true;
}

void CanvasWindowHost::close()
{
  stopRequested_ = true;
  if (thread_.joinable()) {
    thread_.join();
  }
  running_ = false;
}

Application* CanvasWindowHost::app()
{
  return running_.load(std::memory_order_acquire) ? app_.get() : nullptr;
}

void CanvasWindowHost::setFrame(int x, int y, int width, int height)
{
  std::lock_guard lock(mutex_);
  pendingFrame_ = Frame{x, y, width, height};
}

void CanvasWindowHost::setVisible(bool visible)
{
  wantVisible_.store(visible, std::memory_order_release);
  std::lock_guard lock(mutex_);
  pendingVisible_ = visible;
}

bool CanvasWindowHost::isVisible() const
{
  return wantVisible_.load(std::memory_order_acquire);
}

void CanvasWindowHost::applyPendingWindowCommands()
{
  // Caller holds mutex_. Only invoke GLFW from the render thread.
  if (!app_) return;

  if (pendingFrame_) {
    const Frame f = *pendingFrame_;
    pendingFrame_.reset();
    app_->setWindowFrame(f.x, f.y, f.w, f.h);
  }

  if (pendingVisible_) {
    const bool vis = *pendingVisible_;
    pendingVisible_.reset();
    app_->setWindowVisible(vis);
  }
}

void CanvasWindowHost::renderLoop(std::string assetsRoot, uint32_t width,
                                  uint32_t height, std::string title)
{
  {
    std::lock_guard lock(mutex_);
    app_ = std::make_unique<Application>(static_cast<int>(width),
                                         static_cast<int>(height));
    if (auto r = app_->initWithWindow(assetsRoot, title); !r) {
      std::cerr << "CanvasWindowHost: init failed: " << r.error() << '\n';
      app_.reset();
      return;
    }
    // Single-window app: show immediately (no Gtk overlay host).
    app_->setWindowVisible(true);
    wantVisible_.store(true, std::memory_order_release);
  }

  running_.store(true, std::memory_order_release);
  std::cout << "Canvas window open: " << width << "x" << height
            << " \"" << title << "\"\n";

  while (!stopRequested_.load(std::memory_order_acquire)) {
    // Apply host commands first so show/hide/pos always hit the GLFW thread.
    {
      std::lock_guard lock(mutex_);
      applyPendingWindowCommands();
    }

    glfwPollEvents();

    if (app_ && app_->windowShouldClose()) {
      break;
    }

    if (!wantVisible_.load(std::memory_order_acquire)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(16));
      continue;
    }

    {
      std::lock_guard lock(mutex_);
      // Re-apply in case a show+frame arrived this iteration after poll.
      applyPendingWindowCommands();
      if (!app_->repaint()) {
        std::cerr << "CanvasWindowHost: repaint failed\n";
        break;
      }
    }
  }

  {
    std::lock_guard lock(mutex_);
    if (app_) {
      app_->shutdown();
      app_.reset();
    }
  }

  running_.store(false, std::memory_order_release);
  std::cout << "Canvas window closed\n";
}
