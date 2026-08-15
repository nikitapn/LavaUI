#pragma once

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <csignal>
#include <thread>
#include <unistd.h>

namespace lava {

/// A thread that is not the Wayland loop. If startup never produces a
/// frame, it SIGKILLs the process.
///
/// SIGTERM is handled on the event loop via signalfd. A deadlock on that
/// loop — a D-Bus restart waiting for us, a GPU readback waiting for the
/// next submit — never sees SIGTERM. SIGKILL is the signal that cannot
/// be blocked, which is why a wedged session needed a reboot.
///
/// Dismissed from the first output frame. Destroyed on any path that
/// leaves `main` without hanging, so a compositor that fails to start
/// and returns is not then murdered for being slow to exit.
class StartupWatchdog {
 public:
  explicit StartupWatchdog(int timeoutMs) {
    if (timeoutMs <= 0) return;
    timeoutMs_ = timeoutMs;
    instance_.store(this, std::memory_order_release);
    thread_ = std::thread([this] { run(); });
  }

  ~StartupWatchdog() {
    instance_.store(nullptr, std::memory_order_release);
    stop_.store(true, std::memory_order_release);
    if (thread_.joinable()) thread_.join();
  }

  StartupWatchdog(const StartupWatchdog &) = delete;
  StartupWatchdog &operator=(const StartupWatchdog &) = delete;

  /// First successful frame. Safe from the event-loop thread; later
  /// frames see a null instance and skip the store.
  static void dismiss() {
    if (StartupWatchdog *self = instance_.exchange(nullptr,
                                                   std::memory_order_acq_rel)) {
      self->ready_.store(true, std::memory_order_release);
    }
  }

 private:
  void run() {
    using clock = std::chrono::steady_clock;
    const auto deadline =
        clock::now() + std::chrono::milliseconds(timeoutMs_);
    while (!stop_.load(std::memory_order_acquire) &&
           !ready_.load(std::memory_order_acquire)) {
      if (clock::now() >= deadline) {
        // The loop that owns `wlr_log` is the thing that is stuck.
        constexpr char kMsg[] = "startup watchdog: timed out, SIGKILL\n";
        (void)::write(STDERR_FILENO, kMsg, sizeof(kMsg) - 1);
        ::kill(::getpid(), SIGKILL);
        return;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
  }

  int timeoutMs_ = 0;
  std::atomic<bool> ready_{false};
  std::atomic<bool> stop_{false};
  std::thread thread_;
  static inline std::atomic<StartupWatchdog *> instance_{nullptr};
};

/// One-shot killer for teardown. `pkill` / Ctrl+C only deliver SIGTERM
/// or SIGINT to the event loop; if `wl_display_destroy_clients` or the
/// GPU teardown wedges, those signals will never be seen again. This
/// thread is not the loop, so it still fires.
///
/// Detached: a clean exit destroys the thread with the process. There
/// is nothing to join and no dismiss — hanging *is* the failure.
inline void arm_shutdown_watchdog() {
  int timeoutMs = 10000;
  if (const char *off = std::getenv("LAVA_NO_WATCHDOG");
      off != nullptr && off[0] != '\0' && off[0] != '0') {
    return;
  }
  if (const char *ms = std::getenv("LAVA_SHUTDOWN_WATCHDOG_MS")) {
    timeoutMs = std::atoi(ms);
  }
  if (timeoutMs <= 0) return;

  static std::atomic<bool> armed{false};
  if (armed.exchange(true, std::memory_order_acq_rel)) return;

  std::thread([timeoutMs] {
    std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
    constexpr char kMsg[] = "shutdown watchdog: timed out, SIGKILL\n";
    (void)::write(STDERR_FILENO, kMsg, sizeof(kMsg) - 1);
    ::kill(::getpid(), SIGKILL);
  }).detach();
}

}  // namespace lava
