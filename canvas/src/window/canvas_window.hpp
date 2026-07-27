#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

class Application;

/// Owns a GLFW + Vulkan present window and a background render loop.
///
/// Important: all glfw* window calls (show/hide/pos/size) run on the render
/// thread. Swift/host only posts desired frame/visibility; the loop applies
/// them. Calling GLFW from the Swift actor is not thread-safe and was
/// breaking re-show after hide.
class CanvasWindowHost {
 public:
  CanvasWindowHost();
  ~CanvasWindowHost();

  CanvasWindowHost(const CanvasWindowHost&) = delete;
  CanvasWindowHost& operator=(const CanvasWindowHost&) = delete;

  bool open(const std::string& assetsRoot, uint32_t width, uint32_t height,
            const std::string& title);

  void close();

  bool isOpen() const { return running_.load(std::memory_order_acquire); }

  Application* app();
  std::mutex& mutex() { return mutex_; }

  /// Post desired screen-space frame (applied on the render thread).
  void setFrame(int x, int y, int width, int height);

  /// Post desired visibility (applied on the render thread).
  void setVisible(bool visible);
  bool isVisible() const;

 private:
  void renderLoop(std::string assetsRoot, uint32_t width, uint32_t height,
                  std::string title);

  /// Apply any pending setFrame/setVisible under mutex; GLFW calls only.
  void applyPendingWindowCommands();

  struct Frame {
    int x = 0, y = 0, w = 0, h = 0;
  };

  std::unique_ptr<Application> app_;
  std::mutex mutex_;
  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> stopRequested_{false};

  // Desired state from the host (Swift). Render thread is the sole consumer
  // that touches GLFW for these.
  std::optional<Frame> pendingFrame_;
  std::optional<bool> pendingVisible_;
  std::atomic<bool> wantVisible_{true};
};
