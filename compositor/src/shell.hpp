#pragma once

#include <cstdint>
#include <string>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

// `environ` — used as the default envp for `spawnAtHome`.
extern char **environ;

struct wl_event_loop;
struct wl_event_source;

/// The desktop's own parts, started and kept running by the compositor.
///
/// A Linux desktop usually assembles itself: a session manager reads a list of
/// autostart files, launches whatever is in them, and has no opinion about
/// whether the result is a working desktop. That is the right design when the
/// panel is a choice. Here it is not — the dock and the panel are as much part
/// of this desktop as the window frames are, and a session that came up without
/// them would be a bug rather than a configuration.
///
/// So the compositor starts them itself, the way it starts Xwayland, and keeps
/// them running. Two failures, deliberately handled separately because they
/// look nothing alike:
///
///   * **the process ended** — a crash, or somebody killed it. Seen through
///     `SIGCHLD`, which the compositor is the parent for.
///   * **the process is still there and has stopped drawing** — wedged. The
///     operating system sees a healthy process; only the client's own frame
///     loop can say otherwise, which is what `Heartbeat` is.
///
/// Both end the same way: the component is restarted, with a delay that grows
/// if it keeps happening, and a point past which the compositor stops trying
/// and says so. A dock that cannot start is a missing dock; a dock restarted
/// four times a second forever is a desktop that never becomes usable.
namespace lava {

/// One component the compositor is responsible for.
struct ShellComponent {
  /// What it is called, in logs and in the config file: "dock", "panel".
  std::string role;
  /// The program to run. A name is looked up (see `ShellSupervisor::start`);
  /// anything containing a `/` is used as given.
  std::string program;
  /// The `app_id` its surfaces carry, which is how a heartbeat is matched back
  /// to the component that sent it. Empty means "same as the program".
  std::string appId;
};

class ShellSupervisor {
 public:
  ShellSupervisor() = default;
  ~ShellSupervisor();

  ShellSupervisor(const ShellSupervisor &) = delete;
  ShellSupervisor &operator=(const ShellSupervisor &) = delete;

  /// Starts every component and begins watching them.
  ///
  /// Called after the Wayland socket is in the environment and the control
  /// plane is listening, because a component that starts before either has
  /// nothing to connect to and immediately becomes a restart.
  void start(wl_event_loop *loop, std::vector<ShellComponent> components);

  /// "I am still drawing", from a surface belonging to `appId`.
  ///
  /// Attributed by application rather than by process, because the two are not
  /// the same thing to watch: a component that crashed and was restarted is a
  /// new pid drawing the same panel, and what matters is that the panel is
  /// being drawn. Ignored for anything not supervised, which is most clients.
  void heartbeat(const std::string &appId);

  /// Stops everything, in the order a session should go down: ask, then
  /// insist. Safe to call twice.
  void stop();

  /// Where a component named without a path is found: `$LAVA_SHELL_DIR`, then
  /// beside the compositor binary, then this repo's SwiftPM build directory,
  /// then PATH. Public because the key bindings launch one — the application
  /// launcher — that is not supervised but lives in exactly the same places.
  static std::string programPath(const std::string &program);

  /// `posix_spawnp` with the child's working directory set to `$HOME`.
  ///
  /// The compositor process stays in the canvas assets tree so relative
  /// shader loads keep working. Anything it starts for the user — shell
  /// components, the launcher, terminals — must not inherit that path, or
  /// every new shell opens in `…/CanvasResources`. On success writes the
  /// child pid and returns 0; otherwise returns an errno for `strerror`.
  static int spawnAtHome(pid_t *pid, const char *file, char *const argv[],
                         char *const envp[] = environ);

 private:
  struct Supervised {
    ShellComponent component;
    pid_t pid = -1;
    /// When the process was started, and when it last said anything. Both
    /// monotonic milliseconds; 0 for "not yet".
    int64_t startedAt = 0;
    int64_t lastBeat = 0;
    /// When to try again after a failure, or 0 when it is running.
    int64_t restartAt = 0;
    /// Consecutive failures, which is what the backoff and the give-up rule
    /// are counted in. Cleared once it has been up long enough to count as
    /// working.
    int failures = 0;
    /// True once the compositor has stopped trying. It says so once.
    bool abandoned = false;
    /// Set when the compositor asked it to go and is waiting to insist.
    int64_t termedAt = 0;
  };

  void spawn(Supervised &entry);
  void reap();
  void tick();
  /// SIGTERM now, SIGKILL if it is still there at the next tick.
  void retire(Supervised &entry, const char *why);
  Supervised *byAppId(const std::string &appId);
  Supervised *byPid(pid_t pid);

  static int on_sigchld(int signal, void *data);
  static int on_tick(void *data);

  std::vector<Supervised> supervised_;
  wl_event_source *sigchld_ = nullptr;
  wl_event_source *timer_ = nullptr;
  bool stopping_ = false;
};

}  // namespace lava
