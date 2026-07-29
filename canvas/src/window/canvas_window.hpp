#pragma once

#include <cstdint>
#include <memory>
#include <string>

class Application;

/// Owns a GLFW + Vulkan present window, driven by whoever calls it.
///
/// This used to run its own render thread with a mutex guarding the
/// Application, which every host call had to take. Because the loop held that
/// mutex across the whole of repaint() — including a FIFO present that blocks
/// to vsync — every host call queued behind a full frame. Measured cost of
/// acquiring it was ~17ms median and up to 200ms, which is what made hover
/// feel laggy despite the GPU being idle. The same lock also turned a resize
/// that left a fence unsignalled into a whole-app hang.
///
/// So the thread is gone. The caller (Swift) owns the loop: it pumps events
/// and asks for frames on its own thread, which is also the thread that
/// created the window — the arrangement GLFW wants anyway. With one thread
/// there is nothing to serialise, so there is no mutex at all.
class CanvasWindowHost {
 public:
  CanvasWindowHost();
  ~CanvasWindowHost();

  CanvasWindowHost(const CanvasWindowHost&) = delete;
  CanvasWindowHost& operator=(const CanvasWindowHost&) = delete;

  /// Creates the window and engine on the *calling* thread. Every subsequent
  /// call must come from that same thread.
  bool open(const std::string& assetsRoot, uint32_t width, uint32_t height,
            const std::string& title);

  void close();

  /// False once the window has been asked to close.
  bool isOpen() const;

  Application* app() { return app_.get(); }

  /// Processes pending OS events, blocking until one arrives or `timeout`
  /// seconds elapse. Zero polls without blocking; negative blocks until an
  /// event arrives.
  ///
  /// Blocking is the point: an idle UI should cost nothing, and input should
  /// wake the loop immediately rather than after a fixed poll interval.
  void pumpEvents(double timeout);

  /// Renders and presents one frame. False if the frame failed.
  bool renderFrame();

  void setFrame(int x, int y, int width, int height);
  void setVisible(bool visible);
  bool isVisible() const;

 private:
  std::unique_ptr<Application> app_;
  bool open_ = false;
  bool visible_ = true;
};
