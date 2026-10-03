#pragma once

#include <functional>
#include <memory>

struct wl_event_loop;

/// The system's half of locking: logind, on the system bus.
///
/// Three things come from it and one goes back. `loginctl lock-session` and
/// `unlock-session` arrive as the session's `Lock` and `Unlock` signals — the
/// second of which is also the way back in from a text console when the lock
/// screen cannot start at all. `PrepareForSleep` says the machine is about to
/// suspend, and a delay inhibitor taken in advance is what gives the lock time
/// to reach the screen first, so a lid opened later shows the lock and never
/// the desktop. Going back: `SetLockedHint`, which is how the rest of the
/// system (and `loginctl show-session`) learns the session is locked.
///
/// Off for a nested compositor. The session these signals name is the one
/// running *outside* it, and a test compositor that locked whenever the real
/// desktop did — or unlocked it — would be answering for somebody else.
namespace lava {

class Logind {
 public:
  struct Handlers {
    std::function<void()> lock;
    std::function<void()> unlock;
    /// `true` just before suspending, `false` just after resuming.
    std::function<void(bool)> prepareForSleep;
  };

  Logind();
  ~Logind();
  Logind(const Logind &) = delete;
  Logind &operator=(const Logind &) = delete;

  /// Connects and subscribes. False, having said why, when there is no system
  /// bus or no session to belong to — a desktop without these features rather
  /// than an error.
  bool start(wl_event_loop *loop, Handlers handlers);

  void setLockedHint(bool locked);

  /// Holds suspend back until `releaseSleepDelay`, or until logind's own
  /// limit (`InhibitDelayMaxSec`, five seconds by default) runs out. Taken
  /// while awake so it is already held when `PrepareForSleep` arrives.
  void takeSleepDelay();
  void releaseSleepDelay();

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace lava
