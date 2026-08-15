#include "menu/status_notifier.hpp"

#include "menu/menu_import.hpp"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <unordered_map>
#include <vector>

#if defined(CANVAS_HAVE_DBUSMENU)
#include <gio/gio.h>
#endif

namespace canvas {

#if defined(CANVAS_HAVE_DBUSMENU)

namespace {

constexpr const char *kWatcherName = "org.kde.StatusNotifierWatcher";
constexpr const char *kWatcherPath = "/StatusNotifierWatcher";
constexpr const char *kWatcherIface = "org.kde.StatusNotifierWatcher";
constexpr const char *kItemIface = "org.kde.StatusNotifierItem";
constexpr const char *kPropsIface = "org.freedesktop.DBus.Properties";
constexpr const char *kDefaultItemPath = "/StatusNotifierItem";

constexpr const char *kIntrospection = R"XML(
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem">
      <arg name="service" type="s" direction="in"/>
    </method>
    <method name="RegisterStatusNotifierHost">
      <arg name="service" type="s" direction="in"/>
    </method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered">
      <arg type="s"/>
    </signal>
    <signal name="StatusNotifierItemUnregistered">
      <arg type="s"/>
    </signal>
    <signal name="StatusNotifierHostRegistered"/>
    <signal name="StatusNotifierHostUnregistered"/>
  </interface>
</node>
)XML";

/// Split a RegisterStatusNotifierItem argument into bus name + object path.
///
/// The protocol is intentionally messy:
///   * object path alone (`/StatusNotifierItem`) → service is the sender
///   * bus name alone → path defaults to `/StatusNotifierItem`
///   * `uniqueName/path` (what RegisteredStatusNotifierItems lists)
void parseItemService(const char *service, const char *sender,
                      std::string &outName, std::string &outPath)
{
  outName.clear();
  outPath.clear();
  if (service == nullptr || service[0] == '\0') {
    if (sender != nullptr) outName = sender;
    outPath = kDefaultItemPath;
    return;
  }
  if (service[0] == '/') {
    if (sender != nullptr) outName = sender;
    outPath = service;
    return;
  }
  // "name/path" or "name/with/slashes/in/path" — first slash splits service
  // from object path. Unique names are `:1.42`; well-known names have no
  // leading colon but still use the same form.
  const char *slash = std::strchr(service, '/');
  if (slash != nullptr) {
    outName.assign(service, slash);
    outPath = slash;
    return;
  }
  outName = service;
  outPath = kDefaultItemPath;
}

std::string makeItemKey(const std::string &name, const std::string &path)
{
  return name + path;
}

/// Network-order ARGB32 → host RGBA8.
void argbNetToRgba(const guchar *src, size_t nBytes, int w, int h,
                   std::vector<uint8_t> &out)
{
  const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
  out.assign(need, 0);
  if (src == nullptr || nBytes < need) return;
  for (size_t i = 0; i + 3 < need; i += 4) {
    // Network byte order ARGB.
    const uint8_t a = src[i + 0];
    const uint8_t r = src[i + 1];
    const uint8_t g = src[i + 2];
    const uint8_t b = src[i + 3];
    out[i + 0] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    out[i + 3] = a;
  }
}

/// Best-effort icon file for a theme name. Prefers `IconThemePath`, then the
/// usual freedesktop roots. Phase 1: raster only (png/xpm); SVG needs RSVG
/// and can wait for a native applet path.
std::string resolveIconFile(const std::string &name,
                            const std::string &themePath)
{
  if (name.empty()) return {};
  if (name[0] == '/') {
    if (std::filesystem::is_regular_file(name)) return name;
    return {};
  }

  std::vector<std::filesystem::path> roots;
  if (!themePath.empty()) roots.emplace_back(themePath);

  if (const char *home = std::getenv("HOME")) {
    roots.emplace_back(std::filesystem::path(home) / ".local/share/icons");
    roots.emplace_back(std::filesystem::path(home) / ".icons");
  }
  roots.emplace_back("/usr/share/icons");
  roots.emplace_back("/usr/share/pixmaps");

  static const char *kSizes[] = {
      "22x22", "24x24", "16x16", "32x32", "48x48", "scalable", "symbolic"};
  static const char *kCats[] = {
      "apps", "status", "devices", "panel", "actions", "categories", "emblems"};
  static const char *kExts[] = {".png", ".xpm", ".svg"};

  for (const auto &root : roots) {
    // Direct file under theme path / pixmaps.
    for (const char *ext : kExts) {
      const auto direct = root / (name + ext);
      if (std::filesystem::is_regular_file(direct)) return direct.string();
    }
    // hicolor-style layout under an icons root.
    for (const char *size : kSizes) {
      for (const char *cat : kCats) {
        for (const char *ext : kExts) {
          const auto p = root / "hicolor" / size / cat / (name + ext);
          if (std::filesystem::is_regular_file(p)) return p.string();
          // Some themes put icons at root/size/cat without hicolor.
          const auto p2 = root / size / cat / (name + ext);
          if (std::filesystem::is_regular_file(p2)) return p2.string();
        }
      }
    }
  }
  return {};
}

GVariant *getProp(GDBusConnection *conn, const char *name, const char *path,
                  const char *prop)
{
  GError *err = nullptr;
  GVariant *ret = g_dbus_connection_call_sync(
      conn, name, path, kPropsIface, "Get",
      g_variant_new("(ss)", kItemIface, prop), G_VARIANT_TYPE("(v)"),
      G_DBUS_CALL_FLAGS_NONE, 1500, nullptr, &err);
  if (ret == nullptr) {
    if (err) g_error_free(err);
    return nullptr;
  }
  GVariant *inner = nullptr;
  g_variant_get(ret, "(v)", &inner);
  g_variant_unref(ret);
  return inner;
}

std::string propString(GDBusConnection *conn, const char *name,
                       const char *path, const char *prop)
{
  GVariant *v = getProp(conn, name, path, prop);
  if (v == nullptr) return {};
  std::string out;
  if (g_variant_is_of_type(v, G_VARIANT_TYPE_STRING)) {
    out = g_variant_get_string(v, nullptr);
  } else if (g_variant_is_of_type(v, G_VARIANT_TYPE_OBJECT_PATH)) {
    out = g_variant_get_string(v, nullptr);
  }
  g_variant_unref(v);
  return out;
}

bool propBool(GDBusConnection *conn, const char *name, const char *path,
              const char *prop)
{
  GVariant *v = getProp(conn, name, path, prop);
  if (v == nullptr) return false;
  bool out = false;
  if (g_variant_is_of_type(v, G_VARIANT_TYPE_BOOLEAN)) {
    out = g_variant_get_boolean(v);
  }
  g_variant_unref(v);
  return out;
}

/// Whether an object implements `method` on the item interface.
///
/// Introspection rather than "call it and see": the call is fire-and-forget so
/// its failure arrives nowhere useful, and the difference between an applet
/// that acts on a click and one that only has a menu has to be known *before*
/// the click is decided.
bool hasMethod(GDBusConnection *conn, const char *name, const char *path,
               const char *method)
{
  GError *err = nullptr;
  GVariant *ret = g_dbus_connection_call_sync(
      conn, name, path, "org.freedesktop.DBus.Introspectable", "Introspect",
      nullptr, G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, 1500, nullptr,
      &err);
  if (ret == nullptr) {
    if (err) g_error_free(err);
    return false;
  }
  const gchar *xml = nullptr;
  g_variant_get(ret, "(&s)", &xml);
  bool found = false;
  if (xml != nullptr) {
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(xml, nullptr);
    if (node != nullptr) {
      if (GDBusInterfaceInfo *iface =
              g_dbus_node_info_lookup_interface(node, kItemIface)) {
        found = g_dbus_interface_info_lookup_method(iface, method) != nullptr;
      }
      g_dbus_node_info_unref(node);
    }
  }
  g_variant_unref(ret);
  return found;
}

/// Largest pixmap from IconPixmap `a(iiay)`.
void loadPixmap(GDBusConnection *conn, const char *name, const char *path,
                int &outW, int &outH, std::vector<uint8_t> &outRgba)
{
  outW = 0;
  outH = 0;
  outRgba.clear();
  GVariant *v = getProp(conn, name, path, "IconPixmap");
  if (v == nullptr) return;
  if (!g_variant_is_of_type(v, G_VARIANT_TYPE("a(iiay)"))) {
    g_variant_unref(v);
    return;
  }

  int bestW = 0, bestH = 0;
  std::vector<uint8_t> bestArgb;
  GVariantIter iter;
  g_variant_iter_init(&iter, v);
  GVariant *entry = nullptr;
  while ((entry = g_variant_iter_next_value(&iter)) != nullptr) {
    gint32 w = 0, h = 0;
    GVariant *bytes = nullptr;
    g_variant_get(entry, "(ii@ay)", &w, &h, &bytes);
    if (bytes != nullptr && w > 0 && h > 0) {
      gsize len = 0;
      const guchar *data =
          static_cast<const guchar *>(g_variant_get_fixed_array(bytes, &len, 1));
      const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
      if (data != nullptr && len >= need && w * h >= bestW * bestH) {
        bestW = w;
        bestH = h;
        bestArgb.assign(data, data + need);
      }
      g_variant_unref(bytes);
    }
    g_variant_unref(entry);
  }
  g_variant_unref(v);
  if (bestW > 0 && bestH > 0 && !bestArgb.empty()) {
    argbNetToRgba(bestArgb.data(), bestArgb.size(), bestW, bestH, outRgba);
    outW = bestW;
    outH = bestH;
  }
}

} // namespace

struct StatusNotifierHost::Impl {
  struct Item {
    std::string service; ///< Unique bus name preferred.
    std::string path;
    std::string id;
    std::string title;
    std::string status;
    std::string iconName;
    std::string iconThemePath;
    std::string iconPath;
    /// `Menu`: the DBusMenu object this item exports, or empty. For most
    /// applets this is not a fallback but *the* interface — see `hasActivate`.
    std::string menuPath;
    /// Whether the item implements `Activate` at all.
    ///
    /// Read once, by introspection, because the answer decides what a left
    /// click does and there is no way to ask afterwards: a call to a method
    /// that is not there fails asynchronously, long after the click. Ayatana
    /// applets — nm-applet is one — implement none of `Activate`,
    /// `ContextMenu` or even `ItemIsMenu`, and expect the host to open the
    /// DBusMenu itself.
    bool hasActivate = false;
    bool isMenu = false;
    int iconW = 0;
    int iconH = 0;
    std::vector<uint8_t> iconRgba;
    guint nameWatch = 0;
    guint signalSub = 0;
  };

  enum class Mode { None, Own, Follow };

  GDBusConnection *conn = nullptr;
  guint nameToken = 0;
  guint objectToken = 0;
  Mode mode = Mode::None;
  /// Whether the bus has answered our `RequestName` yet, either way. Not the
  /// same question as `mode`: "the name is taken" is an answer, and it leaves
  /// the mode exactly where it started.
  bool nameAnswered = false;
  /// Own mode: hosts that called RegisterStatusNotifierHost (incl. ourselves).
  int hostCount = 0;
  /// Follow mode: subscriptions on the session's watcher.
  guint followRegSub = 0;
  guint followUnregSub = 0;
  bool started = false;

  std::vector<Item> items;
  uint64_t revision = 0;

  /// The open item's DBusMenu, and whose it is. Import-only: this one serves
  /// no registrar — the panel's other importer does that.
  MenuImportHost menu;
  bool menuStarted = false;
  std::string menuKey;

  bool serving() const { return mode == Mode::Own || mode == Mode::Follow; }

  static bool nameHasOwner(GDBusConnection *conn, const char *name)
  {
    GError *err = nullptr;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", name),
        G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &err);
    if (ret == nullptr) {
      if (err) g_error_free(err);
      return false;
    }
    gboolean owned = FALSE;
    g_variant_get(ret, "(b)", &owned);
    g_variant_unref(ret);
    return owned;
  }

  static void onBusNameAcquired(GDBusConnection *, const gchar *,
                                gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    self->nameAnswered = true;
    self->mode = Mode::Own;
    // We are the host: clients check this before RegisterStatusNotifierItem.
    self->hostCount = 1;
    self->emitHostRegistered();
    std::cerr << "canvas: StatusNotifierWatcher owned (" << kWatcherName
              << ")\n";
  }

  static void onBusNameLost(GDBusConnection *, const gchar *, gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    self->nameAnswered = true;
    // With DO_NOT_QUEUE this also fires when the name was already taken —
    // that is not an error; `start` falls through to follow mode.
    if (self->mode == Mode::Own) {
      self->mode = Mode::None;
      std::cerr << "canvas: StatusNotifierWatcher name lost (was owner)\n";
    }
  }

  void emitSignal(const char *name, GVariant *params)
  {
    // Only the real owner may emit watcher signals.
    if (conn == nullptr || mode != Mode::Own) {
      if (params) g_variant_unref(params);
      return;
    }
    g_dbus_connection_emit_signal(conn, nullptr, kWatcherPath, kWatcherIface,
                                  name, params, nullptr);
  }

  void emitItemRegistered(const std::string &key)
  {
    emitSignal("StatusNotifierItemRegistered",
               g_variant_new("(s)", key.c_str()));
  }

  void emitItemUnregistered(const std::string &key)
  {
    emitSignal("StatusNotifierItemUnregistered",
               g_variant_new("(s)", key.c_str()));
  }

  void emitHostRegistered()
  {
    emitSignal("StatusNotifierHostRegistered", nullptr);
  }

  static void onMethodCall(GDBusConnection * /*c*/, const gchar *sender,
                           const gchar * /*path*/, const gchar * /*iface*/,
                           const gchar *method, GVariant *params,
                           GDBusMethodInvocation *invocation,
                           gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    if (g_strcmp0(method, "RegisterStatusNotifierItem") == 0) {
      const gchar *service = nullptr;
      g_variant_get(params, "(&s)", &service);
      self->registerItem(service, sender, /*announce=*/true);
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (g_strcmp0(method, "RegisterStatusNotifierHost") == 0) {
      self->hostCount += 1;
      self->emitHostRegistered();
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    g_dbus_method_invocation_return_dbus_error(
        invocation, "org.freedesktop.DBus.Error.UnknownMethod", method);
  }

  static GVariant *onGetProperty(GDBusConnection *, const gchar *,
                                 const gchar *, const gchar *,
                                 const gchar *property, GError **error,
                                 gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    if (g_strcmp0(property, "ProtocolVersion") == 0) {
      return g_variant_new_int32(0);
    }
    if (g_strcmp0(property, "IsStatusNotifierHostRegistered") == 0) {
      return g_variant_new_boolean(self->hostCount > 0);
    }
    if (g_strcmp0(property, "RegisteredStatusNotifierItems") == 0) {
      GVariantBuilder b;
      g_variant_builder_init(&b, G_VARIANT_TYPE("as"));
      for (const Item &it : self->items) {
        const std::string key = makeItemKey(it.service, it.path);
        g_variant_builder_add(&b, "s", key.c_str());
      }
      return g_variant_builder_end(&b);
    }
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
                "unknown property %s", property);
    return nullptr;
  }

  /// `service` / `sender` as RegisterStatusNotifierItem, or a full key
  /// `name/path` when following another watcher (`sender` null).
  void registerItem(const char *service, const char *sender, bool announce)
  {
    std::string name, path;
    parseItemService(service, sender, name, path);
    if (name.empty() || path.empty()) return;

    const std::string key = makeItemKey(name, path);
    if (Item *existing = find(key)) {
      refreshItem(*existing);
      ++revision;
      return;
    }

    Item it;
    it.service = std::move(name);
    it.path = std::move(path);
    watchItem(it);
    refreshItem(it);
    items.push_back(std::move(it));
    ++revision;
    if (announce) emitItemRegistered(key);
    std::cerr << "canvas: SNI registered " << key << "\n";
  }

  void unregisterByKey(const std::string &key)
  {
    for (size_t i = 0; i < items.size(); ++i) {
      if (makeItemKey(items[i].service, items[i].path) != key) continue;
      unwatchItem(items[i]);
      items.erase(items.begin() + static_cast<std::ptrdiff_t>(i));
      ++revision;
      emitItemUnregistered(key);
      std::cerr << "canvas: SNI unregistered " << key << "\n";
      return;
    }
  }

  void watchItem(Item &it)
  {
    it.nameWatch = g_bus_watch_name_on_connection(
        conn, it.service.c_str(), G_BUS_NAME_WATCHER_FLAGS_NONE, nullptr,
        onNameVanished, this, nullptr);

    it.signalSub = g_dbus_connection_signal_subscribe(
        conn, it.service.c_str(), kItemIface, nullptr, it.path.c_str(),
        nullptr, G_DBUS_SIGNAL_FLAGS_NONE, onItemSignal, this, nullptr);
  }

  static void onNameVanished(GDBusConnection *, const gchar *name,
                             gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    self->removeByService(name);
  }

  static void onItemSignal(GDBusConnection *, const gchar *sender,
                           const gchar *path, const gchar *, const gchar *,
                           GVariant *, gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    if (sender == nullptr || path == nullptr) return;
    const std::string key = makeItemKey(sender, path);
    for (Item &it : self->items) {
      if (makeItemKey(it.service, it.path) == key) {
        self->refreshItem(it);
        ++self->revision;
        return;
      }
    }
  }

  static void onWatcherItemRegistered(GDBusConnection *, const gchar *,
                                      const gchar *, const gchar *,
                                      const gchar *, GVariant *params,
                                      gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    const gchar *key = nullptr;
    g_variant_get(params, "(&s)", &key);
    if (key == nullptr || key[0] == '\0') return;
    // Full `service/path` key from the session watcher — no sender needed.
    self->registerItem(key, nullptr, /*announce=*/false);
  }

  static void onWatcherItemUnregistered(GDBusConnection *, const gchar *,
                                        const gchar *, const gchar *,
                                        const gchar *, GVariant *params,
                                        gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    const gchar *key = nullptr;
    g_variant_get(params, "(&s)", &key);
    if (key == nullptr) return;
    self->unregisterByKey(key);
  }

  void removeByService(const char *name)
  {
    if (name == nullptr) return;
    for (size_t i = 0; i < items.size();) {
      if (items[i].service == name) {
        const std::string key = makeItemKey(items[i].service, items[i].path);
        unwatchItem(items[i]);
        items.erase(items.begin() + static_cast<std::ptrdiff_t>(i));
        ++revision;
        emitItemUnregistered(key);
        std::cerr << "canvas: SNI unregistered " << key << "\n";
      } else {
        ++i;
      }
    }
  }

  void unwatchItem(Item &it)
  {
    if (it.nameWatch != 0) {
      g_bus_unwatch_name(it.nameWatch);
      it.nameWatch = 0;
    }
    if (it.signalSub != 0 && conn != nullptr) {
      g_dbus_connection_signal_unsubscribe(conn, it.signalSub);
      it.signalSub = 0;
    }
  }

  void refreshItem(Item &it)
  {
    const char *n = it.service.c_str();
    const char *p = it.path.c_str();
    it.id = propString(conn, n, p, "Id");
    it.title = propString(conn, n, p, "Title");
    it.status = propString(conn, n, p, "Status");
    it.iconName = propString(conn, n, p, "IconName");
    it.iconThemePath = propString(conn, n, p, "IconThemePath");
    it.isMenu = propBool(conn, n, p, "ItemIsMenu");
    it.menuPath = propString(conn, n, p, "Menu");
    it.hasActivate = hasMethod(conn, n, p, "Activate");
    it.iconPath = resolveIconFile(it.iconName, it.iconThemePath);
    loadPixmap(conn, n, p, it.iconW, it.iconH, it.iconRgba);
    // Attention icon when status asks for it and main icon is empty.
    if (it.status == "NeedsAttention" && it.iconRgba.empty() &&
        it.iconPath.empty()) {
      const std::string att = propString(conn, n, p, "AttentionIconName");
      if (!att.empty()) {
        it.iconName = att;
        it.iconPath = resolveIconFile(att, it.iconThemePath);
      }
    }
  }

  Item *find(const std::string &key)
  {
    for (Item &it : items) {
      if (makeItemKey(it.service, it.path) == key) return &it;
    }
    return nullptr;
  }

  void callItem(const std::string &key, const char *method, int x, int y)
  {
    Item *it = find(key);
    if (it == nullptr || conn == nullptr) return;
    g_dbus_connection_call(conn, it->service.c_str(), it->path.c_str(),
                           kItemIface, method, g_variant_new("(ii)", x, y),
                           nullptr, G_DBUS_CALL_FLAGS_NONE, -1, nullptr,
                           nullptr, nullptr);
  }

  void tearDownOwnObject()
  {
    if (objectToken != 0 && conn != nullptr) {
      g_dbus_connection_unregister_object(conn, objectToken);
      objectToken = 0;
    }
    if (nameToken != 0) {
      g_bus_unown_name(nameToken);
      nameToken = 0;
    }
  }

  bool startOwn()
  {
    GError *err = nullptr;
    GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(kIntrospection, &err);
    if (info == nullptr) {
      std::cerr << "canvas: SNI watcher introspection failed: "
                << (err ? err->message : "?") << "\n";
      if (err) g_error_free(err);
      return false;
    }

    static const GDBusInterfaceVTable vtable = {
        onMethodCall, onGetProperty, nullptr, {nullptr}};
    objectToken = g_dbus_connection_register_object(
        conn, kWatcherPath, info->interfaces[0], &vtable, this, nullptr, &err);
    g_dbus_node_info_unref(info);
    if (objectToken == 0) {
      std::cerr << "canvas: could not export StatusNotifierWatcher: "
                << (err ? err->message : "?") << "\n";
      if (err) g_error_free(err);
      return false;
    }

    nameAnswered = false;
    nameToken = g_bus_own_name_on_connection(
        conn, kWatcherName, G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE,
        onBusNameAcquired, onBusNameLost, this, nullptr);

    // Waited for, not glanced at. `g_bus_own_name_on_connection` is
    // asynchronous and the answer is a round trip to the bus daemon, so
    // draining what happens to be pending the instant after asking dispatches
    // nothing at all: this concluded "name taken" every time, tore down the
    // object it had just exported, found no other watcher to follow either,
    // and gave the session no tray. Every stock applet — nm-applet, Blueman,
    // pasystray — went invisible, with one line in the log to say so.
    //
    // Bounded, because a bus that never answers should cost a panel its tray
    // and not its startup. Two seconds is the same budget the calls around
    // here use.
    const gint64 deadline = g_get_monotonic_time() + 2 * G_TIME_SPAN_SECOND;
    while (!nameAnswered && g_get_monotonic_time() < deadline) {
      while (g_main_context_iteration(nullptr, FALSE)) {
      }
      if (nameAnswered) break;
      g_usleep(500);
    }
    if (mode == Mode::Own) return true;

    // Name taken or lost — drop the unused object so we can follow cleanly.
    tearDownOwnObject();
    return false;
  }

  bool startFollow()
  {
    // Tell the session watcher we are a host (optional for some, required
    // for others to keep IsStatusNotifierHostRegistered true when we are
    // the only consumer that cares — Plasma already has a host).
    const gchar *unique = g_dbus_connection_get_unique_name(conn);
    if (unique != nullptr) {
      GError *err = nullptr;
      GVariant *ret = g_dbus_connection_call_sync(
          conn, kWatcherName, kWatcherPath, kWatcherIface,
          "RegisterStatusNotifierHost", g_variant_new("(s)", unique),
          nullptr, G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &err);
      if (ret) {
        g_variant_unref(ret);
      } else if (err) {
        // Non-fatal: we can still mirror the item list without registering.
        std::cerr << "canvas: RegisterStatusNotifierHost: " << err->message
                  << "\n";
        g_error_free(err);
      }
    }

    followRegSub = g_dbus_connection_signal_subscribe(
        conn, kWatcherName, kWatcherIface, "StatusNotifierItemRegistered",
        kWatcherPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        onWatcherItemRegistered, this, nullptr);
    followUnregSub = g_dbus_connection_signal_subscribe(
        conn, kWatcherName, kWatcherIface, "StatusNotifierItemUnregistered",
        kWatcherPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        onWatcherItemUnregistered, this, nullptr);

    // Snapshot whatever is already registered.
    GError *err = nullptr;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, kWatcherName, kWatcherPath, kPropsIface, "Get",
        g_variant_new("(ss)", kWatcherIface, "RegisteredStatusNotifierItems"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &err);
    if (ret != nullptr) {
      GVariant *inner = nullptr;
      g_variant_get(ret, "(v)", &inner);
      g_variant_unref(ret);
      if (inner != nullptr &&
          g_variant_is_of_type(inner, G_VARIANT_TYPE("as"))) {
        GVariantIter iter;
        g_variant_iter_init(&iter, inner);
        const gchar *key = nullptr;
        while (g_variant_iter_loop(&iter, "s", &key)) {
          if (key != nullptr) registerItem(key, nullptr, /*announce=*/false);
        }
      }
      if (inner) g_variant_unref(inner);
    } else if (err) {
      std::cerr << "canvas: could not list StatusNotifier items: "
                << err->message << "\n";
      g_error_free(err);
    }

    mode = Mode::Follow;
    std::cerr << "canvas: StatusNotifierWatcher follow mode (" << kWatcherName
              << " already owned; mirroring " << items.size() << " item(s))\n";
    return true;
  }
};

StatusNotifierHost::StatusNotifierHost() : impl_(std::make_unique<Impl>()) {}

StatusNotifierHost::~StatusNotifierHost()
{
  if (!impl_) return;
  for (Impl::Item &it : impl_->items) impl_->unwatchItem(it);
  if (impl_->followRegSub != 0 && impl_->conn != nullptr) {
    g_dbus_connection_signal_unsubscribe(impl_->conn, impl_->followRegSub);
  }
  if (impl_->followUnregSub != 0 && impl_->conn != nullptr) {
    g_dbus_connection_signal_unsubscribe(impl_->conn, impl_->followUnregSub);
  }
  impl_->tearDownOwnObject();
  if (impl_->conn != nullptr) g_object_unref(impl_->conn);
}

bool StatusNotifierHost::start()
{
  if (impl_->started) return impl_->serving();
  impl_->started = true;

  GError *err = nullptr;
  impl_->conn = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
  if (impl_->conn == nullptr) {
    std::cerr << "canvas: no session bus for StatusNotifierWatcher: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    return false;
  }

  // Prefer following when the session already has a tray — owning would fail
  // or fight Plasma/GNOME. Try own only when free.
  if (Impl::nameHasOwner(impl_->conn, kWatcherName)) {
    return impl_->startFollow();
  }
  if (impl_->startOwn()) return true;
  // Race: name appeared between check and own.
  if (Impl::nameHasOwner(impl_->conn, kWatcherName)) {
    return impl_->startFollow();
  }
  std::cerr << "canvas: StatusNotifierWatcher unavailable\n";
  return false;
}

bool StatusNotifierHost::isServing() const { return impl_->serving(); }

void StatusNotifierHost::poll()
{
  while (g_main_context_iteration(nullptr, FALSE)) {
  }
  // The open menu rides the same GLib context, but the importer keeps its own
  // dirty flag and only rebuilds its flattened items when told to look.
  if (impl_->menuStarted) impl_->menu.poll();
}

uint64_t StatusNotifierHost::revision() const { return impl_->revision; }

size_t StatusNotifierHost::itemCount() const { return impl_->items.size(); }

std::string StatusNotifierHost::itemKey(size_t index) const
{
  if (index >= impl_->items.size()) return {};
  const auto &it = impl_->items[index];
  return makeItemKey(it.service, it.path);
}

std::string StatusNotifierHost::itemId(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].id : std::string{};
}

std::string StatusNotifierHost::itemTitle(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].title
                                     : std::string{};
}

std::string StatusNotifierHost::itemStatus(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].status
                                     : std::string{};
}

std::string StatusNotifierHost::itemIconName(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconName
                                     : std::string{};
}

std::string StatusNotifierHost::itemIconPath(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconPath
                                     : std::string{};
}

bool StatusNotifierHost::itemIsMenu(size_t index) const
{
  return index < impl_->items.size() && impl_->items[index].isMenu;
}

bool StatusNotifierHost::itemHasMenu(size_t index) const
{
  return index < impl_->items.size() && !impl_->items[index].menuPath.empty();
}

bool StatusNotifierHost::itemPrefersMenu(size_t index) const
{
  if (index >= impl_->items.size()) return false;
  const auto &it = impl_->items[index];
  if (it.menuPath.empty()) return false;
  return it.isMenu || !it.hasActivate;
}

bool StatusNotifierHost::openMenu(const std::string &key)
{
  Impl::Item *it = impl_->find(key);
  if (it == nullptr || it->menuPath.empty()) return false;
  if (!impl_->menuStarted) {
    impl_->menuStarted = impl_->menu.startImportOnly();
    if (!impl_->menuStarted) return false;
  }
  // Window id 0 throughout: this menu was never registered against a window
  // and never will be. The service and path are the whole address.
  impl_->menu.setActiveWindow(0, it->service, it->menuPath);
  impl_->menuKey = key;
  // Applications are allowed to fill the root only when asked, and an applet
  // whose menu is built on demand — nm-applet rebuilds its network list every
  // time — hands back an empty layout otherwise.
  impl_->menu.aboutToShow(0);
  return true;
}

void StatusNotifierHost::closeMenu()
{
  if (impl_->menuKey.empty()) return;
  impl_->menuKey.clear();
  if (impl_->menuStarted) impl_->menu.setActiveWindow(0, {}, {});
}

const std::string &StatusNotifierHost::openMenuKey() const
{
  return impl_->menuKey;
}

uint64_t StatusNotifierHost::menuRevision() const
{
  return impl_->menu.revision();
}

size_t StatusNotifierHost::menuItemCount() const
{
  return impl_->menuKey.empty() ? 0 : impl_->menu.itemCount();
}

int32_t StatusNotifierHost::menuItemId(size_t index) const
{
  return impl_->menu.itemId(index);
}

int32_t StatusNotifierHost::menuItemParent(size_t index) const
{
  return impl_->menu.itemParent(index);
}

std::string StatusNotifierHost::menuItemLabel(size_t index) const
{
  return impl_->menu.itemLabel(index);
}

bool StatusNotifierHost::menuItemEnabled(size_t index) const
{
  return impl_->menu.itemEnabled(index);
}

bool StatusNotifierHost::menuItemSeparator(size_t index) const
{
  return impl_->menu.itemSeparator(index);
}

bool StatusNotifierHost::menuItemHasSubmenu(size_t index) const
{
  return impl_->menu.itemHasSubmenu(index);
}

int StatusNotifierHost::menuItemChecked(size_t index) const
{
  return impl_->menu.itemChecked(index);
}

void StatusNotifierHost::menuActivate(int32_t itemId)
{
  impl_->menu.activate(itemId);
}

void StatusNotifierHost::menuAboutToShow(int32_t itemId)
{
  impl_->menu.aboutToShow(itemId);
}

int StatusNotifierHost::itemIconWidth(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconW : 0;
}

int StatusNotifierHost::itemIconHeight(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconH : 0;
}

size_t StatusNotifierHost::itemIconRgbaSize(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].iconRgba.size() : 0;
}

size_t StatusNotifierHost::itemIconRgbaCopy(size_t index, uint8_t *out,
                                            size_t cap) const
{
  if (index >= impl_->items.size() || out == nullptr || cap == 0) return 0;
  const auto &rgba = impl_->items[index].iconRgba;
  const size_t n = std::min(cap, rgba.size());
  if (n > 0) std::memcpy(out, rgba.data(), n);
  return n;
}

void StatusNotifierHost::activate(const std::string &key, int x, int y)
{
  impl_->callItem(key, "Activate", x, y);
}

void StatusNotifierHost::contextMenu(const std::string &key, int x, int y)
{
  impl_->callItem(key, "ContextMenu", x, y);
}

void StatusNotifierHost::secondaryActivate(const std::string &key, int x,
                                           int y)
{
  impl_->callItem(key, "SecondaryActivate", x, y);
}

void StatusNotifierHost::scroll(const std::string &key, int delta,
                                const std::string &orientation)
{
  Impl::Item *it = impl_->find(key);
  if (it == nullptr || impl_->conn == nullptr) return;
  const char *orient =
      orientation.empty() ? "vertical" : orientation.c_str();
  g_dbus_connection_call(impl_->conn, it->service.c_str(), it->path.c_str(),
                         kItemIface, "Scroll",
                         g_variant_new("(is)", delta, orient), nullptr,
                         G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr,
                         nullptr);
}

#else // !CANVAS_HAVE_DBUSMENU

struct StatusNotifierHost::Impl {};

StatusNotifierHost::StatusNotifierHost() : impl_(std::make_unique<Impl>()) {}
StatusNotifierHost::~StatusNotifierHost() = default;

bool StatusNotifierHost::start() { return false; }
bool StatusNotifierHost::isServing() const { return false; }
void StatusNotifierHost::poll() {}
uint64_t StatusNotifierHost::revision() const { return 0; }
size_t StatusNotifierHost::itemCount() const { return 0; }
std::string StatusNotifierHost::itemKey(size_t) const { return {}; }
std::string StatusNotifierHost::itemId(size_t) const { return {}; }
std::string StatusNotifierHost::itemTitle(size_t) const { return {}; }
std::string StatusNotifierHost::itemStatus(size_t) const { return {}; }
std::string StatusNotifierHost::itemIconName(size_t) const { return {}; }
std::string StatusNotifierHost::itemIconPath(size_t) const { return {}; }
bool StatusNotifierHost::itemIsMenu(size_t) const { return false; }
bool StatusNotifierHost::itemHasMenu(size_t) const { return false; }
bool StatusNotifierHost::itemPrefersMenu(size_t) const { return false; }
bool StatusNotifierHost::openMenu(const std::string &) { return false; }
void StatusNotifierHost::closeMenu() {}
const std::string &StatusNotifierHost::openMenuKey() const
{
  static const std::string none;
  return none;
}
uint64_t StatusNotifierHost::menuRevision() const { return 0; }
size_t StatusNotifierHost::menuItemCount() const { return 0; }
int32_t StatusNotifierHost::menuItemId(size_t) const { return 0; }
int32_t StatusNotifierHost::menuItemParent(size_t) const { return -1; }
std::string StatusNotifierHost::menuItemLabel(size_t) const { return {}; }
bool StatusNotifierHost::menuItemEnabled(size_t) const { return false; }
bool StatusNotifierHost::menuItemSeparator(size_t) const { return false; }
bool StatusNotifierHost::menuItemHasSubmenu(size_t) const { return false; }
int StatusNotifierHost::menuItemChecked(size_t) const { return -1; }
void StatusNotifierHost::menuActivate(int32_t) {}
void StatusNotifierHost::menuAboutToShow(int32_t) {}
int StatusNotifierHost::itemIconWidth(size_t) const { return 0; }
int StatusNotifierHost::itemIconHeight(size_t) const { return 0; }
size_t StatusNotifierHost::itemIconRgbaSize(size_t) const { return 0; }
size_t StatusNotifierHost::itemIconRgbaCopy(size_t, uint8_t *, size_t) const
{
  return 0;
}
void StatusNotifierHost::activate(const std::string &, int, int) {}
void StatusNotifierHost::contextMenu(const std::string &, int, int) {}
void StatusNotifierHost::secondaryActivate(const std::string &, int, int) {}
void StatusNotifierHost::scroll(const std::string &, int, const std::string &)
{}

#endif

} // namespace canvas
