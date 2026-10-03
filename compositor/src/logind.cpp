#include "logind.hpp"

#include <fcntl.h>
#include <systemd/sd-bus.h>
#include <unistd.h>

#include <cstring>
#include <string>

#include <wayland-server-core.h>

#include "wlr.hpp"

namespace lava {

namespace {
constexpr const char *kService = "org.freedesktop.login1";
constexpr const char *kManagerPath = "/org/freedesktop/login1";
constexpr const char *kManager = "org.freedesktop.login1.Manager";
constexpr const char *kSession = "org.freedesktop.login1.Session";
}  // namespace

struct Logind::Impl {
  Handlers handlers;
  sd_bus *bus = nullptr;
  sd_bus_slot *lockSlot = nullptr;
  sd_bus_slot *unlockSlot = nullptr;
  sd_bus_slot *sleepSlot = nullptr;
  wl_event_source *source = nullptr;
  std::string sessionPath;
  int sleepFd = -1;

  ~Impl() {
    if (sleepFd >= 0) ::close(sleepFd);
    if (source != nullptr) wl_event_source_remove(source);
    sd_bus_slot_unref(lockSlot);
    sd_bus_slot_unref(unlockSlot);
    sd_bus_slot_unref(sleepSlot);
    if (bus != nullptr) sd_bus_flush_close_unref(bus);
  }

  static int on_readable(int, uint32_t, void *data) {
    auto *self = static_cast<Impl *>(data);
    int r = 0;
    while ((r = sd_bus_process(self->bus, nullptr)) > 0) {
    }
    if (r < 0) wlr_log(WLR_ERROR, "logind: bus: %s", std::strerror(-r));
    return 0;
  }

  static int on_lock(sd_bus_message *, void *data, sd_bus_error *) {
    auto *self = static_cast<Impl *>(data);
    wlr_log(WLR_INFO, "logind: Lock");
    if (self->handlers.lock) self->handlers.lock();
    return 0;
  }

  static int on_unlock(sd_bus_message *, void *data, sd_bus_error *) {
    auto *self = static_cast<Impl *>(data);
    wlr_log(WLR_INFO, "logind: Unlock");
    if (self->handlers.unlock) self->handlers.unlock();
    return 0;
  }

  static int on_sleep(sd_bus_message *message, void *data, sd_bus_error *) {
    auto *self = static_cast<Impl *>(data);
    int going = 0;
    if (sd_bus_message_read(message, "b", &going) < 0) return 0;
    wlr_log(WLR_INFO, "logind: PrepareForSleep(%s)", going ? "true" : "false");
    if (self->handlers.prepareForSleep) self->handlers.prepareForSleep(going);
    return 0;
  }

  /// The object path of the session this process belongs to.
  bool findSession() {
    // By pid first: that is the session the compositor was started in, which
    // is the one a lid-close locks. `auto` is logind's own fallback for a
    // caller it can place some other way.
    sd_bus_error error = SD_BUS_ERROR_NULL;
    sd_bus_message *reply = nullptr;
    int r = sd_bus_call_method(bus, kService, kManagerPath, kManager,
                               "GetSessionByPID", &error, &reply, "u",
                               static_cast<uint32_t>(::getpid()));
    if (r < 0) {
      sd_bus_error_free(&error);
      error = SD_BUS_ERROR_NULL;
      r = sd_bus_call_method(bus, kService, kManagerPath, kManager,
                             "GetSession", &error, &reply, "s", "auto");
    }
    if (r < 0) {
      wlr_log(WLR_INFO, "logind: no session for this process: %s",
              error.message != nullptr ? error.message : std::strerror(-r));
      sd_bus_error_free(&error);
      return false;
    }
    const char *path = nullptr;
    if (sd_bus_message_read(reply, "o", &path) >= 0 && path != nullptr) {
      sessionPath = path;
    }
    sd_bus_message_unref(reply);
    sd_bus_error_free(&error);
    return !sessionPath.empty();
  }
};

Logind::Logind() = default;
Logind::~Logind() = default;

bool Logind::start(wl_event_loop *loop, Handlers handlers) {
  auto impl = std::make_unique<Impl>();
  impl->handlers = std::move(handlers);
  if (int r = sd_bus_open_system(&impl->bus); r < 0) {
    wlr_log(WLR_INFO, "logind: no system bus: %s", std::strerror(-r));
    return false;
  }
  if (!impl->findSession()) return false;

  int r = sd_bus_match_signal(impl->bus, &impl->lockSlot, kService,
                              impl->sessionPath.c_str(), kSession, "Lock",
                              Impl::on_lock, impl.get());
  if (r >= 0) {
    r = sd_bus_match_signal(impl->bus, &impl->unlockSlot, kService,
                            impl->sessionPath.c_str(), kSession, "Unlock",
                            Impl::on_unlock, impl.get());
  }
  if (r >= 0) {
    r = sd_bus_match_signal(impl->bus, &impl->sleepSlot, kService,
                            kManagerPath, kManager, "PrepareForSleep",
                            Impl::on_sleep, impl.get());
  }
  if (r < 0) {
    wlr_log(WLR_ERROR, "logind: cannot subscribe: %s", std::strerror(-r));
    return false;
  }

  impl->source = wl_event_loop_add_fd(loop, sd_bus_get_fd(impl->bus),
                                      WL_EVENT_READABLE, Impl::on_readable,
                                      impl.get());
  if (impl->source == nullptr) {
    wlr_log(WLR_ERROR, "logind: cannot watch the bus");
    return false;
  }
  // Anything that arrived while subscribing is already buffered, and the fd
  // will not become readable for it again.
  Impl::on_readable(0, 0, impl.get());

  wlr_log(WLR_INFO, "logind: watching %s", impl->sessionPath.c_str());
  impl_ = std::move(impl);
  return true;
}

void Logind::setLockedHint(bool locked) {
  if (!impl_) return;
  sd_bus_error error = SD_BUS_ERROR_NULL;
  if (sd_bus_call_method(impl_->bus, kService, impl_->sessionPath.c_str(),
                         kSession, "SetLockedHint", &error, nullptr, "b",
                         static_cast<int>(locked)) < 0) {
    wlr_log(WLR_INFO, "logind: SetLockedHint: %s",
            error.message != nullptr ? error.message : "failed");
  }
  sd_bus_error_free(&error);
}

void Logind::takeSleepDelay() {
  if (!impl_ || impl_->sleepFd >= 0) return;
  sd_bus_error error = SD_BUS_ERROR_NULL;
  sd_bus_message *reply = nullptr;
  if (sd_bus_call_method(impl_->bus, kService, kManagerPath, kManager,
                         "Inhibit", &error, &reply, "ssss", "sleep", "Lava",
                         "Locking the screen before suspend", "delay") < 0) {
    wlr_log(WLR_INFO, "logind: no sleep delay: %s",
            error.message != nullptr ? error.message : "failed");
    sd_bus_error_free(&error);
    return;
  }
  int fd = -1;
  // The descriptor belongs to the message; ours is a duplicate, and closing
  // it is what releases the delay.
  if (sd_bus_message_read(reply, "h", &fd) >= 0 && fd >= 0) {
    impl_->sleepFd = ::fcntl(fd, F_DUPFD_CLOEXEC, 3);
  }
  sd_bus_message_unref(reply);
  sd_bus_error_free(&error);
}

void Logind::releaseSleepDelay() {
  if (!impl_ || impl_->sleepFd < 0) return;
  ::close(impl_->sleepFd);
  impl_->sleepFd = -1;
}

}  // namespace lava
