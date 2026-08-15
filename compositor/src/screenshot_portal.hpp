#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

struct wl_event_loop;

namespace lava {

/// `org.freedesktop.impl.portal.Screenshot` on the session bus.
///
/// Flameshot does not read pixels. It asks xdg-desktop-portal, which
/// forwards here. We do not capture in the D-Bus handler — a GPU
/// readback on the same thread as the event loop, while the caller is
/// waiting on us, is how a session locks up. The handler only queues;
/// `finish` / `fail` run from the next output commit.
class ScreenshotPortal {
 public:
  /// Ask the compositor to produce a frame we can read. False if there
  /// is no output to capture.
  using Schedule = std::function<bool()>;

  struct Options {
    /// Session bus name. The real session uses the name in lava.portal;
    /// a nested compositor uses a .test suffix so it cannot steal the
    /// desktop's Screenshot impl or restart the user's portal.
    const char *busName = "org.freedesktop.impl.portal.desktop.lava";
    /// Write lava.portal and import XDG_CURRENT_DESKTOP. Off when nested.
    bool claimDesktop = true;
  };

  ScreenshotPortal();
  ~ScreenshotPortal();

  ScreenshotPortal(const ScreenshotPortal &) = delete;
  ScreenshotPortal &operator=(const ScreenshotPortal &) = delete;

  bool start(wl_event_loop *loop, Schedule schedule, Options options);

  bool hasPending() const;

  /// Reply to a queued request with a PNG (already encoded). No-op if
  /// nothing is waiting.
  void finish(const std::vector<uint8_t> &png, uint32_t width, uint32_t height);

  void fail();

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace lava
