#pragma once

// Desktop notifications, from the serving side: own
// `org.freedesktop.Notifications` and keep the list of what is currently on
// screen.
//
// The third of the freedesktop protocols a panel has to speak, after AppMenu
// (`menu_import.hpp`) and StatusNotifier (`status_notifier.hpp`), and built
// the same way for the same reasons: GDBus here, a flat index-addressed list
// out, and a `poll` the frame loop drives. What draws a notification is not
// this class's business — it says what is live and for how long, and a panel
// paints it.
//
// Not a replacement for dunst so much as the absence of one: a desktop with no
// notification daemon silently drops everything anything tries to tell the
// user, and `notify-send` exits with an error nobody sees.
//
// Optional at build time with the same GIO stack as the others
// (`CANVAS_HAVE_DBUSMENU`). Stubbed otherwise, in which case the panel serves
// nothing and another daemon is free to.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace canvas {

/// Serves `org.freedesktop.Notifications` and holds the live ones.
///
/// One process per session may own the name. When something else already does
/// — dunst, or a Plasma session this is nested inside — `start` returns false
/// and this stays inert rather than fighting for it: two daemons showing the
/// same notification twice is worse than one showing it once.
class NotificationHost {
public:
  /// What the sender asked for, resolved.
  ///
  /// `Urgency` matters to more than styling: a critical notification does not
  /// expire on its own, because "your battery is about to die" should not
  /// disappear while you are looking away.
  enum class Urgency : uint8_t { Low = 0, Normal = 1, Critical = 2 };

  /// Why a notification ended. The values are the protocol's, and they go out
  /// in `NotificationClosed`.
  enum class CloseReason : uint32_t {
    Expired = 1,
    Dismissed = 2,
    Requested = 3,
    Undefined = 4,
  };

  NotificationHost();
  ~NotificationHost();

  NotificationHost(const NotificationHost &) = delete;
  NotificationHost &operator=(const NotificationHost &) = delete;

  /// Claims the name. False when the session already has a daemon, or has no
  /// bus at all.
  bool start();
  bool isServing() const;

  /// Iterate GLib once, and retire whatever has run out of time. Call every
  /// frame: an expiry is a timeout the panel is not otherwise watching, and a
  /// notification that outstays it is the most visible bug this can have.
  void poll();

  /// Bumped when the list changes in any way a panel would redraw for.
  uint64_t revision() const;

  size_t count() const;
  /// The protocol's id, which is what `CloseNotification` and the signals
  /// speak in. Stable for the life of the notification, including across a
  /// replacement — `replaces_id` reuses it deliberately.
  uint32_t id(size_t index) const;
  std::string appName(size_t index) const;
  std::string summary(size_t index) const;
  std::string body(size_t index) const;
  /// Resolved icon file for `app_icon` or the `image-path` hint, if one was
  /// found. Empty when the sender passed pixels instead, or nothing.
  std::string iconPath(size_t index) const;
  /// Pixels from the `image-data` hint, RGBA8. The sender's own bitmap beats
  /// any name it also gave, because it is what the sender chose to show.
  int iconWidth(size_t index) const;
  int iconHeight(size_t index) const;
  size_t iconRgbaSize(size_t index) const;
  size_t iconRgbaCopy(size_t index, uint8_t *out, size_t cap) const;
  uint8_t urgency(size_t index) const;
  /// Milliseconds until it expires, or 0 when it never does. Counts down.
  int64_t remainingMs(size_t index) const;

  /// Actions, as the pairs the sender gave: a key it will recognise and a
  /// label to put on a button. The conventional `"default"` key is the one
  /// invoked by clicking the body, and is not drawn as a button.
  size_t actionCount(size_t index) const;
  std::string actionKey(size_t index, size_t action) const;
  std::string actionLabel(size_t index, size_t action) const;

  /// "The user pressed this." Emits `ActionInvoked`, and then closes the
  /// notification as dismissed — which is what senders expect and what every
  /// other daemon does.
  void invokeAction(uint32_t id, const std::string &key);
  /// "The user swatted it away." Emits `NotificationClosed`.
  void dismiss(uint32_t id);
  /// Everything, as dismissed. For a "clear all" button.
  void dismissAll();

  /// Stop the clock while the pointer is over the stack, and start it again
  /// when it leaves. Reading a notification should not be a race.
  void setPaused(bool paused);
  bool isPaused() const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
