#include "shell.hpp"

#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>

#include <wayland-server-core.h>

#include "wlr.hpp"

extern char **environ;

namespace lava {
namespace {

/// How long a freshly started component may take to say anything.
///
/// It has to connect, open a surface, load its fonts and draw a frame before
/// the first beat arrives, and on a cold page cache that is not instant. Too
/// short and the compositor kills a component that was merely starting, which
/// looks exactly like the crash loop this exists to avoid.
constexpr int64_t kStartupGraceMs = 20'000;

/// How long a component may be silent before it is treated as wedged. Several
/// beats' worth: a client sends one every two seconds, so this is a handful of
/// consecutive misses rather than one unlucky datagram.
constexpr int64_t kSilenceMs = 12'000;

/// How long to wait after SIGTERM before SIGKILL.
constexpr int64_t kTermGraceMs = 2'000;

/// Restart delays, indexed by consecutive failure. A component that dies once
/// comes straight back; one that keeps dying is backed off so the log stays
/// readable and the machine stays usable.
constexpr int64_t kBackoffMs[] = {250, 1'000, 3'000, 8'000, 20'000};

/// Consecutive failures before the compositor stops trying. Five restarts of
/// something that will not run says the binary is broken, not the moment.
constexpr int kMaxFailures = 5;

/// How long a component must stay up before its failure count is forgiven.
/// Longer than the whole backoff ladder, so "it starts, runs for a minute,
/// dies" is not mistaken for a fresh problem every time.
constexpr int64_t kStableMs = 60'000;

/// The tick. Everything here is measured in seconds, so once a second is
/// enough resolution and cheap enough not to think about.
constexpr int kTickMs = 1'000;

int64_t now_ms() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return int64_t{ts.tv_sec} * 1000 + ts.tv_nsec / 1'000'000;
}

bool executable(const std::filesystem::path &path) {
  std::error_code ec;
  return std::filesystem::is_regular_file(path, ec) &&
         ::access(path.c_str(), X_OK) == 0;
}

/// The directory this compositor's own binary is in.
std::filesystem::path exeDir() {
  std::error_code ec;
  const std::filesystem::path self =
      std::filesystem::read_symlink("/proc/self/exe", ec);
  return ec ? std::filesystem::path{} : self.parent_path();
}

}  // namespace

std::string ShellSupervisor::programPath(const std::string &program) {
  // A path is a path: whoever wrote it in the config meant that file.
  if (program.find('/') != std::string::npos) return program;

  std::vector<std::filesystem::path> roots;
  if (const char *dir = std::getenv("LAVA_SHELL_DIR")) roots.emplace_back(dir);

  const std::filesystem::path exe = exeDir();
  if (!exe.empty()) {
    // Installed: the shell sits beside the compositor.
    roots.push_back(exe);
    // Built from this tree: the compositor is meson's (build/compositor/) and
    // the components are SwiftPM's (.build/debug/), which is two levels up and
    // sideways. Worth encoding, because the alternative is a developer whose
    // desktop silently comes up without a dock and no clue why.
    roots.push_back(exe / ".." / ".." / ".build" / "debug");
    roots.push_back(exe / ".." / ".." / ".build" / "release");
  }

  for (const auto &root : roots) {
    const std::filesystem::path candidate = root / program;
    if (executable(candidate)) {
      std::error_code ec;
      const auto absolute = std::filesystem::canonical(candidate, ec);
      return ec ? candidate.string() : absolute.string();
    }
  }

  // Nothing found: hand the bare name to posix_spawnp, which searches PATH.
  // A component installed properly is found here and nowhere above.
  return program;
}

ShellSupervisor::~ShellSupervisor() { stop(); }

void ShellSupervisor::start(wl_event_loop *loop,
                            std::vector<ShellComponent> components) {
  if (loop == nullptr || components.empty()) return;

  for (ShellComponent &component : components) {
    if (component.appId.empty()) {
      component.appId = std::filesystem::path(component.program).filename();
    }
    Supervised entry;
    entry.component = std::move(component);
    supervised_.push_back(std::move(entry));
  }

  // SIGCHLD through the loop rather than a handler: reaping touches this
  // object, and almost nothing here would be safe to call from a signal
  // context. `main` blocks it before any thread exists so the signalfd can
  // see it — the same reason SIGHUP is blocked there.
  sigchld_ = wl_event_loop_add_signal(loop, SIGCHLD, on_sigchld, this);
  timer_ = wl_event_loop_add_timer(loop, on_tick, this);

  for (Supervised &entry : supervised_) spawn(entry);

  if (timer_ != nullptr) wl_event_source_timer_update(timer_, kTickMs);
}

int ShellSupervisor::spawnAtHome(pid_t *outPid, const char *file,
                                 char *const argv[], char *const envp[]) {
  pid_t pid = -1;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_t *actionsPtr = nullptr;
  const char *home = std::getenv("HOME");
  // `addchdir_np` puts the child in $HOME without racing the compositor's own
  // cwd (which is the assets tree for shader loads). Missing HOME keeps the
  // inherited directory — better a wrong cwd than refusing to start.
  if (home != nullptr && home[0] != '\0') {
    if (posix_spawn_file_actions_init(&actions) == 0) {
      if (posix_spawn_file_actions_addchdir_np(&actions, home) == 0) {
        actionsPtr = &actions;
      } else {
        posix_spawn_file_actions_destroy(&actions);
      }
    }
  }
  const int error =
      posix_spawnp(&pid, file, actionsPtr, nullptr, argv, envp);
  if (actionsPtr != nullptr) {
    posix_spawn_file_actions_destroy(actionsPtr);
  }
  if (error != 0) return error;
  if (outPid != nullptr) *outPid = pid;
  return 0;
}

void ShellSupervisor::spawn(Supervised &entry) {
  const std::string path = programPath(entry.component.program);

  std::string program = path;
  char *argv[] = {program.data(), nullptr};

  pid_t pid = -1;
  // `p` so a bare name still finds something on PATH; `resolve` has already
  // preferred anything nearer. Home cwd: see spawnAtHome.
  const int error = spawnAtHome(&pid, program.c_str(), argv, environ);
  if (error != 0) {
    wlr_log(WLR_ERROR, "shell: cannot start %s (%s): %s",
            entry.component.role.c_str(), program.c_str(),
            std::strerror(error));
    ++entry.failures;
    entry.pid = -1;
    entry.restartAt =
        now_ms() + kBackoffMs[std::min<size_t>(
                       entry.failures, std::size(kBackoffMs)) - 1];
    return;
  }

  entry.pid = pid;
  entry.startedAt = now_ms();
  entry.lastBeat = 0;
  entry.restartAt = 0;
  entry.termedAt = 0;
  wlr_log(WLR_INFO, "shell: started %s: %s (pid %d)",
          entry.component.role.c_str(), program.c_str(),
          static_cast<int>(pid));
}

void ShellSupervisor::heartbeat(const std::string &appId) {
  if (Supervised *entry = byAppId(appId)) entry->lastBeat = now_ms();
}

ShellSupervisor::Supervised *ShellSupervisor::byAppId(const std::string &appId) {
  if (appId.empty()) return nullptr;
  for (Supervised &entry : supervised_) {
    if (entry.component.appId == appId) return &entry;
  }
  return nullptr;
}

ShellSupervisor::Supervised *ShellSupervisor::byPid(pid_t pid) {
  for (Supervised &entry : supervised_) {
    if (entry.pid == pid) return &entry;
  }
  return nullptr;
}

int ShellSupervisor::on_sigchld(int, void *data) {
  static_cast<ShellSupervisor *>(data)->reap();
  return 0;
}

void ShellSupervisor::reap() {
  // Every exited child, not just ours: this is the only SIGCHLD handler in the
  // process, and a launcher started from a key binding leaves a zombie
  // otherwise. Its own waiter thread may win the race, which is fine — one of
  // the two collects it and the other sees ECHILD.
  for (;;) {
    int status = 0;
    const pid_t pid = ::waitpid(-1, &status, WNOHANG);
    if (pid <= 0) break;

    Supervised *entry = byPid(pid);
    if (entry == nullptr) continue;

    entry->pid = -1;
    if (stopping_) continue;

    const int64_t now = now_ms();
    const bool wasUp = entry->startedAt > 0 && now - entry->startedAt >= kStableMs;
    if (wasUp) entry->failures = 0;
    ++entry->failures;

    if (entry->failures > kMaxFailures) {
      if (!entry->abandoned) {
        entry->abandoned = true;
        wlr_log(WLR_ERROR,
                "shell: %s failed %d times in a row; not starting it again "
                "(fix it and reload with SIGHUP)",
                entry->component.role.c_str(), entry->failures - 1);
      }
      continue;
    }

    const int64_t delay =
        kBackoffMs[std::min<size_t>(entry->failures, std::size(kBackoffMs)) - 1];
    entry->restartAt = now + delay;
    // Which signal, not just "a signal": SIGTERM means somebody asked it to
    // go and SIGSEGV means it fell over, and telling those apart from the log
    // is the difference between looking for a crash and looking for whoever
    // sent it.
    char how[32];
    if (WIFSIGNALED(status)) {
      std::snprintf(how, sizeof(how), "signal %d", WTERMSIG(status));
    } else {
      std::snprintf(how, sizeof(how), "exit %d", WEXITSTATUS(status));
    }
    wlr_log(WLR_INFO, "shell: %s ended (%s); restarting in %lldms",
            entry->component.role.c_str(), how,
            static_cast<long long>(delay));
  }
}

int ShellSupervisor::on_tick(void *data) {
  auto *self = static_cast<ShellSupervisor *>(data);
  self->tick();
  if (self->timer_ != nullptr) {
    wl_event_source_timer_update(self->timer_, kTickMs);
  }
  return 0;
}

void ShellSupervisor::tick() {
  if (stopping_) return;
  const int64_t now = now_ms();

  for (Supervised &entry : supervised_) {
    if (entry.pid < 0) {
      if (!entry.abandoned && entry.restartAt != 0 && now >= entry.restartAt) {
        spawn(entry);
      }
      continue;
    }

    // Asked to go and still here: insist.
    if (entry.termedAt != 0) {
      if (now - entry.termedAt >= kTermGraceMs) {
        wlr_log(WLR_ERROR, "shell: %s ignored SIGTERM; killing it",
                entry.component.role.c_str());
        ::kill(entry.pid, SIGKILL);
        entry.termedAt = now;  // do not spam; SIGCHLD ends this
      }
      continue;
    }

    // Silence. Measured from the last beat, or from the start for a component
    // that has never sent one — a client that never gets as far as drawing is
    // exactly as useless as one that stopped.
    const int64_t since = entry.lastBeat != 0 ? now - entry.lastBeat
                                              : now - entry.startedAt;
    const int64_t allowed = entry.lastBeat != 0 ? kSilenceMs : kStartupGraceMs;
    if (since > allowed) {
      retire(entry,
             entry.lastBeat != 0 ? "stopped drawing" : "never drew anything");
    }
  }
}

void ShellSupervisor::retire(Supervised &entry, const char *why) {
  if (entry.pid < 0) return;
  wlr_log(WLR_ERROR, "shell: %s %s; restarting it",
          entry.component.role.c_str(), why);
  entry.termedAt = now_ms();
  ::kill(entry.pid, SIGTERM);
}

void ShellSupervisor::stop() {
  if (stopping_) return;
  stopping_ = true;

  for (Supervised &entry : supervised_) {
    if (entry.pid > 0) ::kill(entry.pid, SIGTERM);
  }

  if (timer_ != nullptr) {
    wl_event_source_remove(timer_);
    timer_ = nullptr;
  }
  if (sigchld_ != nullptr) {
    wl_event_source_remove(sigchld_);
    sigchld_ = nullptr;
  }

  // Collected rather than left to init: the compositor is on its way out and a
  // brief wait keeps the session's children from outliving the session. Bounded
  // because a component that will not go is not worth hanging the exit for.
  const int64_t deadline = now_ms() + kTermGraceMs;
  for (Supervised &entry : supervised_) {
    while (entry.pid > 0 && now_ms() < deadline) {
      if (::waitpid(entry.pid, nullptr, WNOHANG) == entry.pid) {
        entry.pid = -1;
        break;
      }
      ::usleep(20'000);
    }
    if (entry.pid > 0) {
      ::kill(entry.pid, SIGKILL);
      ::waitpid(entry.pid, nullptr, 0);
      entry.pid = -1;
    }
  }
}

}  // namespace lava
