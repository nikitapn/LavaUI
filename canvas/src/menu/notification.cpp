#include "menu/notification.hpp"

#include <algorithm>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <iostream>

#if defined(CANVAS_HAVE_DBUSMENU)
#include <gio/gio.h>
#endif

namespace canvas {

#if defined(CANVAS_HAVE_DBUSMENU)

namespace {

constexpr const char *kBusName = "org.freedesktop.Notifications";
constexpr const char *kObjectPath = "/org/freedesktop/Notifications";
constexpr const char *kIface = "org.freedesktop.Notifications";

/// How long a notification with no opinion stays up. The specification says
/// the server decides; five seconds is what every daemon settled on.
constexpr int64_t kDefaultTimeoutMs = 5'000;

/// Ceiling for what a sender may ask for, critical excepted. Without it, one
/// `expire_timeout` of an hour parks a toast over the desktop for an hour.
constexpr int64_t kMaxTimeoutMs = 60'000;

constexpr const char *kIntrospection = R"XML(
<node>
  <interface name="org.freedesktop.Notifications">
    <method name="Notify">
      <arg name="app_name" type="s" direction="in"/>
      <arg name="replaces_id" type="u" direction="in"/>
      <arg name="app_icon" type="s" direction="in"/>
      <arg name="summary" type="s" direction="in"/>
      <arg name="body" type="s" direction="in"/>
      <arg name="actions" type="as" direction="in"/>
      <arg name="hints" type="a{sv}" direction="in"/>
      <arg name="expire_timeout" type="i" direction="in"/>
      <arg name="id" type="u" direction="out"/>
    </method>
    <method name="CloseNotification">
      <arg name="id" type="u" direction="in"/>
    </method>
    <method name="GetCapabilities">
      <arg name="capabilities" type="as" direction="out"/>
    </method>
    <method name="GetServerInformation">
      <arg name="name" type="s" direction="out"/>
      <arg name="vendor" type="s" direction="out"/>
      <arg name="version" type="s" direction="out"/>
      <arg name="spec_version" type="s" direction="out"/>
    </method>
    <signal name="NotificationClosed">
      <arg name="id" type="u"/>
      <arg name="reason" type="u"/>
    </signal>
    <signal name="ActionInvoked">
      <arg name="id" type="u"/>
      <arg name="action_key" type="s"/>
    </signal>
  </interface>
</node>
)XML";

int64_t nowMs()
{
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return int64_t{ts.tv_sec} * 1000 + ts.tv_nsec / 1'000'000;
}

/// An icon name or path from `app_icon` / the `image-path` hint, as a file.
///
/// Same search as the tray's, deliberately: an application's notification icon
/// and its tray icon come from the same themes and are named the same way.
std::string resolveIconFile(const std::string &name)
{
  if (name.empty()) return {};
  // `file://` is allowed here where it is not in the tray, because desktop
  // entries hand applications absolute URIs and they pass them straight on.
  std::string path = name;
  if (path.rfind("file://", 0) == 0) path = path.substr(7);
  if (path[0] == '/') {
    return std::filesystem::is_regular_file(path) ? path : std::string{};
  }

  std::vector<std::filesystem::path> roots;
  if (const char *home = std::getenv("HOME")) {
    roots.emplace_back(std::filesystem::path(home) / ".local/share/icons");
    roots.emplace_back(std::filesystem::path(home) / ".icons");
  }
  roots.emplace_back("/usr/share/icons");
  roots.emplace_back("/usr/share/pixmaps");

  static const char *kSizes[] = {"48x48", "64x64", "32x32", "24x24",
                                 "22x22", "scalable", "symbolic"};
  static const char *kCats[] = {"apps", "status", "devices", "actions",
                                "categories", "panel"};
  static const char *kExts[] = {".png", ".xpm", ".svg"};

  for (const auto &root : roots) {
    for (const char *ext : kExts) {
      const auto direct = root / (path + ext);
      if (std::filesystem::is_regular_file(direct)) return direct.string();
    }
    for (const char *size : kSizes) {
      for (const char *cat : kCats) {
        for (const char *ext : kExts) {
          const auto p = root / "hicolor" / size / cat / (path + ext);
          if (std::filesystem::is_regular_file(p)) return p.string();
          const auto p2 = root / size / cat / (path + ext);
          if (std::filesystem::is_regular_file(p2)) return p2.string();
        }
      }
    }
  }
  return {};
}

/// The `image-data` hint: `(iiibiiay)` — width, height, rowstride, alpha,
/// bits per sample, channels, data. Converted to tightly packed RGBA8.
///
/// Worth handling rather than falling back to the name: a chat notification's
/// avatar and a screenshot's thumbnail arrive this way and have no name at
/// all.
bool decodeImageData(GVariant *v, int &outW, int &outH,
                     std::vector<uint8_t> &outRgba)
{
  if (v == nullptr || !g_variant_is_of_type(v, G_VARIANT_TYPE("(iiibiiay)"))) {
    return false;
  }
  gint32 w = 0, h = 0, stride = 0, bits = 0, channels = 0;
  gboolean alpha = FALSE;
  GVariant *bytes = nullptr;
  g_variant_get(v, "(iiibii@ay)", &w, &h, &stride, &alpha, &bits, &channels,
                &bytes);
  if (bytes == nullptr) return false;

  gsize len = 0;
  const auto *src =
    static_cast<const uint8_t *>(g_variant_get_fixed_array(bytes, &len, 1));
  const bool sane = src != nullptr && w > 0 && h > 0 && bits == 8 &&
                    (channels == 3 || channels == 4) && stride >= w * channels &&
                    len >= static_cast<gsize>(stride) * (h - 1) + w * channels;
  if (!sane) {
    g_variant_unref(bytes);
    return false;
  }

  outW = w;
  outH = h;
  outRgba.assign(static_cast<size_t>(w) * h * 4, 0xff);
  for (int y = 0; y < h; ++y) {
    const uint8_t *row = src + static_cast<size_t>(y) * stride;
    uint8_t *dst = outRgba.data() + static_cast<size_t>(y) * w * 4;
    for (int x = 0; x < w; ++x) {
      dst[x * 4 + 0] = row[x * channels + 0];
      dst[x * 4 + 1] = row[x * channels + 1];
      dst[x * 4 + 2] = row[x * channels + 2];
      dst[x * 4 + 3] = channels == 4 ? row[x * channels + 3] : 0xff;
    }
  }
  g_variant_unref(bytes);
  return true;
}

/// One hint, whatever it was called. Senders disagree about `image-data` vs
/// `image_data` vs the deprecated `icon_data`, and a chat client picking the
/// old name is not a reason to lose its avatar.
GVariant *lookupHint(GVariant *hints, std::initializer_list<const char *> names)
{
  for (const char *name : names) {
    if (GVariant *v = g_variant_lookup_value(hints, name, nullptr)) return v;
  }
  return nullptr;
}

} // namespace

struct NotificationHost::Impl {
  struct Action {
    std::string key;
    std::string label;
  };

  struct Item {
    uint32_t id = 0;
    std::string appName;
    std::string summary;
    std::string body;
    std::string iconPath;
    int iconW = 0;
    int iconH = 0;
    std::vector<uint8_t> iconRgba;
    Urgency urgency = Urgency::Normal;
    std::vector<Action> actions;
    /// Monotonic milliseconds, or 0 for "stays until dismissed".
    int64_t expiresAt = 0;
    /// What is left of its life while paused, so the clock can be restarted
    /// where it stopped rather than from the beginning.
    int64_t remainingWhenPaused = 0;
  };

  GDBusConnection *conn = nullptr;
  guint objectToken = 0;
  guint nameToken = 0;
  bool nameAnswered = false;
  bool owned = false;

  std::vector<Item> items;
  uint64_t revision = 0;
  uint32_t nextId = 1;
  bool paused = false;

  Item *find(uint32_t id)
  {
    for (Item &it : items) {
      if (it.id == id) return &it;
    }
    return nullptr;
  }

  void emitSignal(const char *name, GVariant *params)
  {
    if (conn == nullptr) return;
    g_dbus_connection_emit_signal(conn, nullptr, kObjectPath, kIface, name,
                                  params, nullptr);
  }

  void close(uint32_t id, CloseReason reason)
  {
    const auto it = std::find_if(items.begin(), items.end(),
                                 [id](const Item &i) { return i.id == id; });
    if (it == items.end()) return;
    items.erase(it);
    ++revision;
    emitSignal("NotificationClosed",
               g_variant_new("(uu)", id, static_cast<uint32_t>(reason)));
  }

  /// Retire whatever ran out of time. Called from `poll`.
  void expire()
  {
    if (paused) return;
    const int64_t now = nowMs();
    // Collected first: closing emits a signal, and emitting inside the loop
    // that is walking `items` invites a re-entrant `Notify` to reallocate it.
    std::vector<uint32_t> done;
    for (const Item &it : items) {
      if (it.expiresAt != 0 && it.expiresAt <= now) done.push_back(it.id);
    }
    for (uint32_t id : done) close(id, CloseReason::Expired);
  }

  uint32_t notify(const gchar *appName, uint32_t replacesId,
                  const gchar *appIcon, const gchar *summary, const gchar *body,
                  GVariant *actions, GVariant *hints, gint32 expireTimeout)
  {
    Item item;
    item.appName = appName ? appName : "";
    item.summary = summary ? summary : "";
    item.body = body ? body : "";

    if (actions != nullptr) {
      // Flat list of alternating key and label, which is the protocol's idea
      // of a list of pairs.
      GVariantIter iter;
      g_variant_iter_init(&iter, actions);
      const gchar *entry = nullptr;
      std::string pendingKey;
      bool haveKey = false;
      while (g_variant_iter_loop(&iter, "&s", &entry)) {
        if (!haveKey) {
          pendingKey = entry ? entry : "";
          haveKey = true;
        } else {
          item.actions.push_back({pendingKey, entry ? entry : ""});
          haveKey = false;
        }
      }
    }

    if (hints != nullptr) {
      if (GVariant *urgency = lookupHint(hints, {"urgency"})) {
        if (g_variant_is_of_type(urgency, G_VARIANT_TYPE_BYTE)) {
          const uint8_t raw = g_variant_get_byte(urgency);
          item.urgency = raw > 2 ? Urgency::Normal : static_cast<Urgency>(raw);
        }
        g_variant_unref(urgency);
      }
      if (GVariant *image =
            lookupHint(hints, {"image-data", "image_data", "icon_data"})) {
        decodeImageData(image, item.iconW, item.iconH, item.iconRgba);
        g_variant_unref(image);
      }
      if (item.iconRgba.empty()) {
        if (GVariant *path = lookupHint(hints, {"image-path", "image_path"})) {
          if (g_variant_is_of_type(path, G_VARIANT_TYPE_STRING)) {
            item.iconPath = resolveIconFile(g_variant_get_string(path, nullptr));
          }
          g_variant_unref(path);
        }
      }
    }
    if (item.iconRgba.empty() && item.iconPath.empty() && appIcon != nullptr) {
      item.iconPath = resolveIconFile(appIcon);
    }

    // Timeout: -1 means "you decide", 0 means never. Critical never expires
    // whatever it asked for — the specification's own rule.
    int64_t life = kDefaultTimeoutMs;
    if (expireTimeout == 0) {
      life = 0;
    } else if (expireTimeout > 0) {
      life = std::min<int64_t>(expireTimeout, kMaxTimeoutMs);
    }
    if (item.urgency == Urgency::Critical) life = 0;
    item.expiresAt = life == 0 ? 0 : nowMs() + life;
    item.remainingWhenPaused = life;

    // Replacement keeps the id and the place in the stack: a progress
    // notification updating itself must not jump to the front on every
    // percent.
    if (replacesId != 0) {
      if (Item *existing = find(replacesId)) {
        item.id = replacesId;
        *existing = std::move(item);
        ++revision;
        return replacesId;
      }
    }

    item.id = replacesId != 0 ? replacesId : nextId++;
    if (nextId == 0) nextId = 1; // The protocol reserves 0 for "new".
    items.push_back(std::move(item));
    ++revision;
    return items.back().id;
  }

  static void onMethodCall(GDBusConnection * /*conn*/, const gchar * /*sender*/,
                           const gchar * /*path*/, const gchar * /*iface*/,
                           const gchar *method, GVariant *params,
                           GDBusMethodInvocation *invocation, gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);

    if (g_strcmp0(method, "Notify") == 0) {
      const gchar *appName = nullptr;
      const gchar *appIcon = nullptr;
      const gchar *summary = nullptr;
      const gchar *body = nullptr;
      guint32 replacesId = 0;
      gint32 expireTimeout = -1;
      GVariant *actions = nullptr;
      GVariant *hints = nullptr;
      g_variant_get(params, "(&su&s&s&s@as@a{sv}i)", &appName, &replacesId,
                    &appIcon, &summary, &body, &actions, &hints,
                    &expireTimeout);
      const uint32_t id = self->notify(appName, replacesId, appIcon, summary,
                                       body, actions, hints, expireTimeout);
      if (actions) g_variant_unref(actions);
      if (hints) g_variant_unref(hints);
      g_dbus_method_invocation_return_value(invocation,
                                            g_variant_new("(u)", id));
      return;
    }

    if (g_strcmp0(method, "CloseNotification") == 0) {
      guint32 id = 0;
      g_variant_get(params, "(u)", &id);
      self->close(id, CloseReason::Requested);
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }

    if (g_strcmp0(method, "GetCapabilities") == 0) {
      // Only what is actually true. Claiming `body-markup` and then printing
      // the tags is how a notification ends up reading `<b>Warning</b>`.
      static const gchar *const caps[] = {"body", "icon-static", "actions",
                                          "persistence", nullptr};
      g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(^as)", caps));
      return;
    }

    if (g_strcmp0(method, "GetServerInformation") == 0) {
      g_dbus_method_invocation_return_value(
        invocation,
        g_variant_new("(ssss)", "lava", "lava", "1.0", "1.2"));
      return;
    }

    g_dbus_method_invocation_return_dbus_error(
      invocation, "org.freedesktop.DBus.Error.UnknownMethod", method);
  }

  static void onNameAcquired(GDBusConnection *, const gchar *,
                             gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    self->nameAnswered = true;
    self->owned = true;
    std::cerr << "canvas: notifications served (" << kBusName << ")\n";
  }

  static void onNameLost(GDBusConnection *, const gchar *, gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    self->nameAnswered = true;
    if (self->owned) {
      self->owned = false;
      std::cerr << "canvas: notifications name lost (was serving)\n";
    }
  }
};

NotificationHost::NotificationHost() : impl_(std::make_unique<Impl>()) {}

NotificationHost::~NotificationHost()
{
  if (!impl_) return;
  if (impl_->objectToken != 0 && impl_->conn != nullptr) {
    g_dbus_connection_unregister_object(impl_->conn, impl_->objectToken);
  }
  if (impl_->nameToken != 0) g_bus_unown_name(impl_->nameToken);
  if (impl_->conn != nullptr) g_object_unref(impl_->conn);
}

bool NotificationHost::start()
{
  if (impl_->nameToken != 0) return impl_->owned;

  GError *err = nullptr;
  impl_->conn = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
  if (impl_->conn == nullptr) {
    std::cerr << "canvas: no session bus for notifications: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    return false;
  }

  GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(kIntrospection, &err);
  if (info == nullptr) {
    std::cerr << "canvas: notification introspection failed: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    return false;
  }
  static const GDBusInterfaceVTable vtable = {Impl::onMethodCall, nullptr,
                                              nullptr, {nullptr}};
  impl_->objectToken = g_dbus_connection_register_object(
    impl_->conn, kObjectPath, info->interfaces[0], &vtable, impl_.get(),
    nullptr, &err);
  g_dbus_node_info_unref(info);
  if (impl_->objectToken == 0) {
    std::cerr << "canvas: could not export the notification object: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    return false;
  }

  impl_->nameAnswered = false;
  impl_->nameToken = g_bus_own_name_on_connection(
    impl_->conn, kBusName, G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE,
    Impl::onNameAcquired, Impl::onNameLost, impl_.get(), nullptr);

  // Waited for, not glanced at: the answer is a round trip to the bus daemon,
  // and reading the flag before it lands says "taken" every time. The tray
  // learned this the hard way — see `StatusNotifierHost::startOwn`.
  const gint64 deadline = g_get_monotonic_time() + 2 * G_TIME_SPAN_SECOND;
  while (!impl_->nameAnswered && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(nullptr, FALSE)) {
    }
    if (impl_->nameAnswered) break;
    g_usleep(500);
  }

  if (!impl_->owned) {
    // Another daemon has it. Leave it alone and say so once: a session with
    // dunst running is not a broken session.
    std::cerr << "canvas: notifications already served by another daemon\n";
    g_dbus_connection_unregister_object(impl_->conn, impl_->objectToken);
    impl_->objectToken = 0;
    g_bus_unown_name(impl_->nameToken);
    impl_->nameToken = 0;
  }
  return impl_->owned;
}

bool NotificationHost::isServing() const { return impl_->owned; }

void NotificationHost::poll()
{
  if (!impl_->owned) return;
  while (g_main_context_iteration(nullptr, FALSE)) {
  }
  impl_->expire();
}

uint64_t NotificationHost::revision() const { return impl_->revision; }

size_t NotificationHost::count() const { return impl_->items.size(); }

uint32_t NotificationHost::id(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].id : 0;
}

std::string NotificationHost::appName(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].appName
                                     : std::string{};
}

std::string NotificationHost::summary(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].summary
                                     : std::string{};
}

std::string NotificationHost::body(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].body : std::string{};
}

std::string NotificationHost::iconPath(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconPath
                                     : std::string{};
}

int NotificationHost::iconWidth(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconW : 0;
}

int NotificationHost::iconHeight(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconH : 0;
}

size_t NotificationHost::iconRgbaSize(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconRgba.size() : 0;
}

size_t NotificationHost::iconRgbaCopy(size_t index, uint8_t *out,
                                      size_t cap) const
{
  if (index >= impl_->items.size() || out == nullptr || cap == 0) return 0;
  const auto &rgba = impl_->items[index].iconRgba;
  const size_t n = std::min(cap, rgba.size());
  if (n > 0) std::memcpy(out, rgba.data(), n);
  return n;
}

uint8_t NotificationHost::urgency(size_t index) const
{
  return index < impl_->items.size()
           ? static_cast<uint8_t>(impl_->items[index].urgency)
           : 1;
}

int64_t NotificationHost::remainingMs(size_t index) const
{
  if (index >= impl_->items.size()) return 0;
  const auto &item = impl_->items[index];
  if (item.expiresAt == 0) return 0;
  if (impl_->paused) return item.remainingWhenPaused;
  return std::max<int64_t>(0, item.expiresAt - nowMs());
}

size_t NotificationHost::actionCount(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].actions.size() : 0;
}

std::string NotificationHost::actionKey(size_t index, size_t action) const
{
  if (index >= impl_->items.size()) return {};
  const auto &actions = impl_->items[index].actions;
  return action < actions.size() ? actions[action].key : std::string{};
}

std::string NotificationHost::actionLabel(size_t index, size_t action) const
{
  if (index >= impl_->items.size()) return {};
  const auto &actions = impl_->items[index].actions;
  return action < actions.size() ? actions[action].label : std::string{};
}

void NotificationHost::invokeAction(uint32_t id, const std::string &key)
{
  if (impl_->find(id) == nullptr) return;
  impl_->emitSignal("ActionInvoked",
                    g_variant_new("(us)", id, key.c_str()));
  // Then gone. A sender that wants it to stay says so by sending it again,
  // and every other daemon behaves this way.
  impl_->close(id, NotificationHost::CloseReason::Dismissed);
}

void NotificationHost::dismiss(uint32_t id)
{
  impl_->close(id, CloseReason::Dismissed);
}

void NotificationHost::dismissAll()
{
  std::vector<uint32_t> ids;
  ids.reserve(impl_->items.size());
  for (const auto &item : impl_->items) ids.push_back(item.id);
  for (uint32_t id : ids) impl_->close(id, CloseReason::Dismissed);
}

void NotificationHost::setPaused(bool paused)
{
  if (impl_->paused == paused) return;
  impl_->paused = paused;
  const int64_t now = nowMs();
  for (auto &item : impl_->items) {
    if (item.expiresAt == 0) continue;
    if (paused) {
      item.remainingWhenPaused = std::max<int64_t>(0, item.expiresAt - now);
    } else {
      item.expiresAt = now + item.remainingWhenPaused;
    }
  }
}

bool NotificationHost::isPaused() const { return impl_->paused; }

#else // !CANVAS_HAVE_DBUSMENU

struct NotificationHost::Impl {};

NotificationHost::NotificationHost() : impl_(std::make_unique<Impl>()) {}
NotificationHost::~NotificationHost() = default;

bool NotificationHost::start() { return false; }
bool NotificationHost::isServing() const { return false; }
void NotificationHost::poll() {}
uint64_t NotificationHost::revision() const { return 0; }
size_t NotificationHost::count() const { return 0; }
uint32_t NotificationHost::id(size_t) const { return 0; }
std::string NotificationHost::appName(size_t) const { return {}; }
std::string NotificationHost::summary(size_t) const { return {}; }
std::string NotificationHost::body(size_t) const { return {}; }
std::string NotificationHost::iconPath(size_t) const { return {}; }
int NotificationHost::iconWidth(size_t) const { return 0; }
int NotificationHost::iconHeight(size_t) const { return 0; }
size_t NotificationHost::iconRgbaSize(size_t) const { return 0; }
size_t NotificationHost::iconRgbaCopy(size_t, uint8_t *, size_t) const
{
  return 0;
}
uint8_t NotificationHost::urgency(size_t) const { return 1; }
int64_t NotificationHost::remainingMs(size_t) const { return 0; }
size_t NotificationHost::actionCount(size_t) const { return 0; }
std::string NotificationHost::actionKey(size_t, size_t) const { return {}; }
std::string NotificationHost::actionLabel(size_t, size_t) const { return {}; }
void NotificationHost::invokeAction(uint32_t, const std::string &) {}
void NotificationHost::dismiss(uint32_t) {}
void NotificationHost::dismissAll() {}
void NotificationHost::setPaused(bool) {}
bool NotificationHost::isPaused() const { return false; }

#endif

} // namespace canvas
