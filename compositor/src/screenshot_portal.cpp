#include "screenshot_portal.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <spawn.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#include <systemd/sd-bus.h>
#include <wayland-server-core.h>

extern "C" {
#include <wlr/util/log.h>
}

extern char **environ;

namespace lava {
namespace {

constexpr const char *kObjectPath = "/org/freedesktop/portal/desktop";
constexpr const char *kInterface = "org.freedesktop.impl.portal.Screenshot";
constexpr int kPendingTimeoutMs = 2000;

void mkdir_p(const std::string &path) {
  std::string cur;
  for (size_t i = 0; i < path.size(); ++i) {
    cur.push_back(path[i]);
    if (path[i] == '/' || i + 1 == path.size()) {
      if (cur.size() > 1) ::mkdir(cur.c_str(), 0755);
    }
  }
}

bool write_portal_file(const char *busName) {
  const char *home = std::getenv("HOME");
  const char *data = std::getenv("XDG_DATA_HOME");
  std::string dir;
  if (data != nullptr && data[0] != '\0') {
    dir = std::string(data) + "/xdg-desktop-portal/portals";
  } else if (home != nullptr) {
    dir = std::string(home) + "/.local/share/xdg-desktop-portal/portals";
  } else {
    return false;
  }
  mkdir_p(dir);
  const std::string path = dir + "/lava.portal";
  std::ofstream out(path);
  if (!out) return false;
  out << "[portal]\n"
         "DBusName="
      << busName
      << "\n"
         "Interfaces="
      << kInterface
      << ";\n"
         "UseIn=Lava;\n";
  return static_cast<bool>(out);
}

bool write_png_file(const std::vector<uint8_t> &png, std::string &outPath) {
  char tmpl[] = "/tmp/lava-shot-XXXXXX.png";
  const int fd = ::mkstemps(tmpl, 4);
  if (fd < 0) return false;
  const uint8_t *p = png.data();
  size_t left = png.size();
  while (left > 0) {
    const ssize_t n = ::write(fd, p, left);
    if (n < 0) {
      ::close(fd);
      ::unlink(tmpl);
      return false;
    }
    p += static_cast<size_t>(n);
    left -= static_cast<size_t>(n);
  }
  ::close(fd);
  outPath = tmpl;
  return true;
}

/// Fire and forget. Never wait: a compositor that `system()`s
/// `systemctl restart xdg-desktop-portal` deadlocks — the portal comes
/// back, asks us for a screenshot, and we are still inside `system()`.
void spawn_no_wait(const char *file, char *const argv[]) {
  pid_t pid = 0;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  const int err = posix_spawnp(&pid, file, &actions, nullptr, argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  if (err != 0) {
    wlr_log(WLR_ERROR, "screenshot portal: spawn %s: %s", file,
            std::strerror(err));
  }
}

}  // namespace

struct ScreenshotPortal::Impl {
  Schedule schedule;
  sd_bus *bus = nullptr;
  sd_bus_slot *slot = nullptr;
  wl_event_source *source = nullptr;
  wl_event_source *timeout = nullptr;
  sd_bus_message *pending = nullptr;
};

int on_bus(int, uint32_t, void *data) {
  auto *self = static_cast<ScreenshotPortal::Impl *>(data);
  int r = 0;
  while ((r = sd_bus_process(self->bus, nullptr)) > 0) {
  }
  if (r < 0) {
    wlr_log(WLR_ERROR, "screenshot portal: bus: %s", std::strerror(-r));
  }
  return 0;
}

int reply_status(sd_bus_message *m, uint32_t response, const char *uri) {
  sd_bus_message *reply = nullptr;
  if (int r = sd_bus_message_new_method_return(m, &reply); r < 0) return r;
  sd_bus_message_append(reply, "u", response);
  sd_bus_message_open_container(reply, 'a', "{sv}");
  if (uri != nullptr) {
    sd_bus_message_open_container(reply, 'e', "sv");
    sd_bus_message_append(reply, "s", "uri");
    sd_bus_message_open_container(reply, 'v', "s");
    sd_bus_message_append(reply, "s", uri);
    sd_bus_message_close_container(reply);
    sd_bus_message_close_container(reply);
  }
  sd_bus_message_close_container(reply);
  const int r = sd_bus_send(sd_bus_message_get_bus(m), reply, nullptr);
  sd_bus_message_unref(reply);
  return r < 0 ? r : 1;
}

void drop_pending(ScreenshotPortal::Impl *self, uint32_t response,
                  const char *uri) {
  if (self->timeout != nullptr) {
    wl_event_source_timer_update(self->timeout, 0);
  }
  if (self->pending == nullptr) return;
  reply_status(self->pending, response, uri);
  sd_bus_message_unref(self->pending);
  self->pending = nullptr;
}

int on_timeout(void *data) {
  auto *self = static_cast<ScreenshotPortal::Impl *>(data);
  wlr_log(WLR_ERROR, "screenshot portal: capture timed out");
  drop_pending(self, 2, nullptr);
  return 0;
}

int method_screenshot(sd_bus_message *m, void *userdata, sd_bus_error *error) {
  auto *self = static_cast<ScreenshotPortal::Impl *>(userdata);
  if (int r = sd_bus_message_skip(m, "ossa{sv}"); r < 0) {
    return sd_bus_error_set_errno(error, r);
  }
  // Already serving one: do not pile GPU work on a compositor that is
  // mid-capture, and do not leave Flameshot without a reply.
  if (self->pending != nullptr) {
    return reply_status(m, 2, nullptr);
  }
  if (!self->schedule || !self->schedule()) {
    wlr_log(WLR_ERROR, "screenshot portal: no output to capture");
    return reply_status(m, 2, nullptr);
  }
  self->pending = sd_bus_message_ref(m);
  if (self->timeout != nullptr) {
    wl_event_source_timer_update(self->timeout, kPendingTimeoutMs);
  }
  wlr_log(WLR_INFO, "screenshot portal: queued, waiting for the next frame");
  return 1;
}

int method_pick_color(sd_bus_message *m, void *, sd_bus_error *) {
  return reply_status(m, 2, nullptr);
}

int property_version(sd_bus *, const char *, const char *, const char *,
                     sd_bus_message *reply, void *, sd_bus_error *) {
  return sd_bus_message_append(reply, "u", 2u);
}

const sd_bus_vtable kVtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Screenshot", "ossa{sv}", "ua{sv}", method_screenshot, 0),
    SD_BUS_METHOD("PickColor", "ossa{sv}", "ua{sv}", method_pick_color, 0),
    SD_BUS_PROPERTY("version", "u", property_version, 0,
                    SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_VTABLE_END,
};

ScreenshotPortal::ScreenshotPortal() = default;

ScreenshotPortal::~ScreenshotPortal() {
  if (!impl_) return;
  drop_pending(impl_.get(), 2, nullptr);
  if (impl_->timeout != nullptr) wl_event_source_remove(impl_->timeout);
  if (impl_->source != nullptr) wl_event_source_remove(impl_->source);
  sd_bus_slot_unref(impl_->slot);
  sd_bus_flush(impl_->bus);
  sd_bus_unref(impl_->bus);
}

bool ScreenshotPortal::start(wl_event_loop *loop, Schedule schedule,
                             Options options) {
  if (loop == nullptr || !schedule) return false;
  if (options.busName == nullptr || options.busName[0] == '\0') return false;

  if (options.claimDesktop) {
    setenv("XDG_CURRENT_DESKTOP", "Lava", 1);
    if (!write_portal_file(options.busName)) {
      wlr_log(WLR_ERROR, "screenshot portal: could not write lava.portal");
      return false;
    }
  }

  auto impl = std::make_unique<Impl>();
  impl->schedule = std::move(schedule);

  int r = sd_bus_open_user(&impl->bus);
  if (r < 0) {
    wlr_log(WLR_ERROR, "screenshot portal: no session bus: %s",
            std::strerror(-r));
    return false;
  }

  r = sd_bus_add_object_vtable(impl->bus, &impl->slot, kObjectPath, kInterface,
                               kVtable, impl.get());
  if (r < 0) {
    wlr_log(WLR_ERROR, "screenshot portal: vtable: %s", std::strerror(-r));
    return false;
  }

  r = sd_bus_request_name(impl->bus, options.busName, 0);
  if (r < 0) {
    wlr_log(WLR_ERROR, "screenshot portal: name %s: %s", options.busName,
            std::strerror(-r));
    return false;
  }

  const int fd = sd_bus_get_fd(impl->bus);
  if (fd < 0) {
    wlr_log(WLR_ERROR, "screenshot portal: no bus fd");
    return false;
  }
  impl->source =
      wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, on_bus, impl.get());
  if (impl->source == nullptr) {
    wlr_log(WLR_ERROR, "screenshot portal: could not watch the bus");
    return false;
  }
  impl->timeout = wl_event_loop_add_timer(loop, on_timeout, impl.get());

  if (options.claimDesktop &&
      ::access("/usr/bin/dbus-update-activation-environment", X_OK) == 0) {
    char prog[] = "dbus-update-activation-environment";
    char flag[] = "--systemd";
    char a[] = "WAYLAND_DISPLAY";
    char b[] = "XDG_CURRENT_DESKTOP";
    char c[] = "DISPLAY";
    char *argv[] = {prog, flag, a, b, c, nullptr};
    spawn_no_wait(prog, argv);
  }

  impl_ = std::move(impl);
  wlr_log(WLR_INFO, "screenshot portal: %s on the session bus%s",
          options.busName, options.claimDesktop ? "" : " (test)");
  return true;
}

bool ScreenshotPortal::hasPending() const {
  return impl_ != nullptr && impl_->pending != nullptr;
}

void ScreenshotPortal::finish(const std::vector<uint8_t> &png, uint32_t width,
                              uint32_t height) {
  if (!hasPending()) return;
  std::string path;
  if (png.empty() || !write_png_file(png, path)) {
    fail();
    return;
  }
  const std::string uri = "file://" + path;
  wlr_log(WLR_INFO, "screenshot portal: %ux%u → %s", width, height,
          path.c_str());
  drop_pending(impl_.get(), 0, uri.c_str());
}

void ScreenshotPortal::fail() {
  if (!hasPending()) return;
  wlr_log(WLR_ERROR, "screenshot portal: capture failed");
  drop_pending(impl_.get(), 2, nullptr);
}

}  // namespace lava
