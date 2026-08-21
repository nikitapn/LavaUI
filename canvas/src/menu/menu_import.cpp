#include "menu/menu_import.hpp"

#include <cstdlib>
#include <iostream>
#include <unordered_map>
#include <vector>

#if defined(CANVAS_HAVE_DBUSMENU)
#include <gio/gio.h>
#include <libdbusmenu-glib/dbusmenu-glib.h>
#endif

namespace canvas {

#if defined(CANVAS_HAVE_DBUSMENU)

namespace {

constexpr const char *kCanonicalName = "com.canonical.AppMenu.Registrar";
constexpr const char *kLavaName = "org.lavaui.AppMenu.Registrar";
constexpr const char *kRegistrarPath = "/com/canonical/AppMenu/Registrar";
constexpr const char *kRegistrarIface = "com.canonical.AppMenu.Registrar";

/// The registrar, as the applications on the bus expect to find it.
///
/// Written out rather than generated because it is the contract: this is the
/// interface Qt's `QDBusMenuBar` and GTK's appmenu shim look for, argument
/// names and all, and it has not changed since Unity.
constexpr const char *kIntrospection = R"XML(
<node>
  <interface name="com.canonical.AppMenu.Registrar">
    <method name="RegisterWindow">
      <arg type="u" name="windowId" direction="in"/>
      <arg type="o" name="menuObjectPath" direction="in"/>
    </method>
    <method name="UnregisterWindow">
      <arg type="u" name="windowId" direction="in"/>
    </method>
    <method name="GetMenuForWindow">
      <arg type="u" name="windowId" direction="in"/>
      <arg type="s" name="service" direction="out"/>
      <arg type="o" name="menuObjectPath" direction="out"/>
    </method>
    <signal name="WindowRegistered">
      <arg type="u" name="windowId"/>
      <arg type="s" name="service"/>
      <arg type="o" name="menuObjectPath"/>
    </signal>
    <signal name="WindowUnregistered">
      <arg type="u" name="windowId"/>
    </signal>
  </interface>
</node>
)XML";

/// A label as the panel should draw it.
///
/// DBusMenu labels carry GTK mnemonics — "_File", "Save _As" — where the
/// underscore marks the accelerator letter and a doubled one is a literal.
/// Drawing them raw is how a menu ends up reading "_File", which is the most
/// obvious way to look like a menu written by somebody who did not finish.
std::string withoutMnemonics(const char *raw)
{
  if (raw == nullptr) return {};
  std::string out;
  for (const char *p = raw; *p != '\0'; ++p) {
    if (*p != '_') {
      out.push_back(*p);
      continue;
    }
    // "__" is one literal underscore; a lone one is the marker and goes.
    if (*(p + 1) == '_') {
      out.push_back('_');
      ++p;
    }
  }
  return out;
}

} // namespace

struct MenuImportHost::Impl {
  /// One application's claim: where its menu lives.
  struct Registration {
    std::string service;    ///< The unique bus name that called us.
    std::string objectPath;
    uint32_t pid = 0;       ///< GetConnectionUnixProcessID of `service`.
  };

  static bool debug() {
    static const bool on = [] {
      const char *e = std::getenv("LAVA_MENU_DEBUG");
      return e != nullptr && e[0] != '\0' && e[0] != '0';
    }();
    return on;
  }

  static uint32_t pidOfSender(GDBusConnection *conn, const gchar *sender) {
    if (conn == nullptr || sender == nullptr || sender[0] == '\0') return 0;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetConnectionUnixProcessID",
        g_variant_new("(s)", sender), G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    if (ret == nullptr) return 0;
    guint pid = 0;
    g_variant_get(ret, "(u)", &pid);
    g_variant_unref(ret);
    return pid;
  }

  /// One row of the flattened menu — see the header for why it is flat.
  struct Item {
    int32_t id = 0;
    int32_t parent = -1;
    std::string label;
    bool enabled = true;
    bool separator = false;
    bool submenu = false;
    int checked = -1;
  };

  GDBusConnection *conn = nullptr;
  guint nameToken = 0;
  guint objectToken = 0;
  std::string busName;
  bool nameAcquired = false;

  std::unordered_map<uint32_t, Registration> windows;

  uint32_t active = 0;
  uint32_t activePid = 0;
  /// When set, open this DBus object instead of looking up `active` in
  /// `windows`. Filled from the KDE Wayland AppMenu protocol.
  std::string activeService;
  std::string activePath;
  DbusmenuClient *client = nullptr;
  /// The address the open client was created with, resolved.
  std::string openService;
  std::string openPath;
  /// Registrar key the open client was resolved from, or 0 for kde-appmenu.
  uint32_t openWindowId = 0;
  std::vector<Item> items;
  bool dirty = false;
  uint64_t revision = 0;

  // ─── Registrar service ─────────────────────────────────────────────────

  static void onMethodCall(GDBusConnection * /*conn*/, const gchar * sender,
                           const gchar * /*path*/, const gchar * /*iface*/,
                           const gchar *method, GVariant *params,
                           GDBusMethodInvocation *invocation,
                           gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    if (g_strcmp0(method, "RegisterWindow") == 0) {
      guint32 windowId = 0;
      const gchar *path = nullptr;
      g_variant_get(params, "(u&o)", &windowId, &path);
      // The *sender's* unique name, not anything it told us: an application
      // that could name its own service could name somebody else's, and the
      // bus already knows who called.
      const uint32_t pid = pidOfSender(self->conn, sender);
      self->windows[windowId] = Registration{
          sender ? sender : "", path ? path : "", pid};
      std::cerr << "canvas: appmenu RegisterWindow id=" << windowId
                << " pid=" << pid << " " << (sender ? sender : "?") << " "
                << (path ? path : "?") << "\n";
      self->emitRegistered(windowId, sender ? sender : "", path ? path : "");
      // The window this arrives for is often the one already focused: an
      // application registers its menu a moment after its window appears, and
      // by then the panel has long since been told what is active.
      //
      // Qt5 on Wayland registers as id 1, not the compositor surface id, so
      // also match the sender's pid against the focused client.
      if (windowId == self->active ||
          (pid != 0 && pid == self->activePid)) {
        self->openClient();
      }
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (g_strcmp0(method, "UnregisterWindow") == 0) {
      guint32 windowId = 0;
      g_variant_get(params, "(u)", &windowId);
      std::cerr << "canvas: appmenu UnregisterWindow id=" << windowId << "\n";
      self->windows.erase(windowId);
      self->emitUnregistered(windowId);
      if (windowId == self->openWindowId) self->closeClient();
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (g_strcmp0(method, "GetMenuForWindow") == 0) {
      guint32 windowId = 0;
      g_variant_get(params, "(u)", &windowId);
      auto it = self->windows.find(windowId);
      if (it == self->windows.end()) {
        g_dbus_method_invocation_return_dbus_error(
          invocation, "com.canonical.AppMenu.Registrar.Error.WindowNotFound",
          "no menu registered for that window");
        return;
      }
      g_dbus_method_invocation_return_value(
        invocation, g_variant_new("(so)", it->second.service.c_str(),
                                  it->second.objectPath.c_str()));
      return;
    }
    g_dbus_method_invocation_return_dbus_error(
      invocation, "org.freedesktop.DBus.Error.UnknownMethod", "no such method");
  }

  void emitRegistered(uint32_t windowId, const std::string &service,
                      const std::string &path)
  {
    if (conn == nullptr) return;
    g_dbus_connection_emit_signal(
      conn, nullptr, kRegistrarPath, kRegistrarIface, "WindowRegistered",
      g_variant_new("(uso)", static_cast<guint32>(windowId), service.c_str(),
                    path.c_str()),
      nullptr);
  }

  void emitUnregistered(uint32_t windowId)
  {
    if (conn == nullptr) return;
    g_dbus_connection_emit_signal(
      conn, nullptr, kRegistrarPath, kRegistrarIface, "WindowUnregistered",
      g_variant_new("(u)", static_cast<guint32>(windowId)), nullptr);
  }

  // ─── Importing one window's menu ───────────────────────────────────────

  static void onLayoutUpdated(DbusmenuClient * /*client*/, guint /*revision*/,
                              gint /*parent*/, gpointer userData)
  {
    static_cast<Impl *>(userData)->dirty = true;
  }

  static void onRootChanged(DbusmenuClient * /*client*/,
                            DbusmenuMenuitem * /*root*/, gpointer userData)
  {
    static_cast<Impl *>(userData)->dirty = true;
  }

  void closeClient()
  {
    if (client != nullptr) {
      g_signal_handlers_disconnect_by_data(client, this);
      g_object_unref(client);
      client = nullptr;
    }
    items.clear();
    openService.clear();
    openPath.clear();
    openWindowId = 0;
    dirty = false;
    ++revision;
  }

  void openClient()
  {
    closeClient();
    std::string service;
    std::string path;
    const char *how = "none";
    uint32_t viaId = 0;
    if (!activeService.empty() && !activePath.empty()) {
      // Explicit address from kde-appmenu — skip the registrar.
      service = activeService;
      path = activePath;
      how = "kde-appmenu";
    } else {
      auto it = windows.find(active);
      if (it != windows.end()) {
        service = it->second.service;
        path = it->second.objectPath;
        viaId = it->first;
        how = "registrar-id";
      } else if (activePid != 0) {
        for (const auto &kv : windows) {
          if (kv.second.pid != activePid) continue;
          service = kv.second.service;
          path = kv.second.objectPath;
          viaId = kv.first;
          how = "registrar-pid";
          break;
        }
      }
    }

    std::cerr << "canvas: appmenu open id=" << active << " pid=" << activePid
              << " via " << how;
    if (service.empty()) {
      std::cerr << " (no menu)\n";
      return;
    }
    std::cerr << " " << service << " " << path << "\n";

    // Kept for `mergeToggleProperties`, which has to ask the same object for
    // what the library did not.
    openService = service;
    openPath = path;
    openWindowId = viaId;

    client = dbusmenu_client_new(service.c_str(), path.c_str());
    if (client == nullptr) {
      std::cerr << "canvas: dbusmenu client for window " << active
                << " (" << service << " " << path
                << ") could not be created\n";
      return;
    }
    g_signal_connect(client, DBUSMENU_CLIENT_SIGNAL_LAYOUT_UPDATED,
                     G_CALLBACK(onLayoutUpdated), this);
    g_signal_connect(client, DBUSMENU_CLIENT_SIGNAL_ROOT_CHANGED,
                     G_CALLBACK(onRootChanged), this);
    // The layout arrives asynchronously; `poll` picks it up when the root
    // appears. Marked dirty so the first poll after this looks.
    dirty = true;
  }

  /// Chromium/Electron (VSCode, Teams) put File/Edit on the bar with
  /// `children-display=submenu` and no children. AboutToShow fills them, but
  /// always returns needUpdate=false, so libdbusmenu never GetLayouts again
  /// and the dropdown stays empty. Ask the object ourselves and ignore the
  /// boolean — KDE's importer does the same.
  bool aboutToShowSync(int32_t id)
  {
    if (conn == nullptr || openService.empty() || openPath.empty()) return false;
    GError *err = nullptr;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, openService.c_str(), openPath.c_str(), "com.canonical.dbusmenu",
        "AboutToShow", g_variant_new("(i)", id), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &err);
    if (ret == nullptr) {
      if (debug() && err != nullptr) {
        std::cerr << "canvas: appmenu AboutToShow(" << id << ") "
                  << err->message << "\n";
      }
      if (err) g_error_free(err);
      return false;
    }
    gboolean need = FALSE;
    g_variant_get(ret, "(b)", &need);
    g_variant_unref(ret);
    if (debug()) {
      std::cerr << "canvas: appmenu AboutToShow id=" << id
                << " needUpdate=" << (need ? "true" : "false") << "\n";
    }
    return true;
  }

  void parseLayoutNode(GVariant *node, int32_t parentId, bool skipSelf)
  {
    if (node == nullptr ||
        !g_variant_is_of_type(node, G_VARIANT_TYPE("(ia{sv}av)"))) {
      return;
    }
    gint32 id = 0;
    GVariantIter *props = nullptr;
    GVariantIter *kids = nullptr;
    g_variant_get(node, "(ia{sv}av)", &id, &props, &kids);

    Item item;
    item.id = id;
    item.parent = parentId;
    bool visible = true;
    bool checkable = false;
    int toggleState = 0;
    const gchar *key = nullptr;
    GVariant *value = nullptr;
    while (g_variant_iter_loop(props, "{&sv}", &key, &value)) {
      if (g_strcmp0(key, "label") == 0 &&
          g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
        item.label = withoutMnemonics(g_variant_get_string(value, nullptr));
      } else if (g_strcmp0(key, "type") == 0 &&
                 g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
        item.separator =
            g_strcmp0(g_variant_get_string(value, nullptr), "separator") == 0;
      } else if (g_strcmp0(key, "enabled") == 0 &&
                 g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN)) {
        item.enabled = g_variant_get_boolean(value) != FALSE;
      } else if (g_strcmp0(key, "visible") == 0 &&
                 g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN)) {
        visible = g_variant_get_boolean(value) != FALSE;
      } else if (g_strcmp0(key, "children-display") == 0 &&
                 g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
        item.submenu = g_strcmp0(g_variant_get_string(value, nullptr),
                                 "submenu") == 0;
      } else if (g_strcmp0(key, "toggle-type") == 0 &&
                 g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
        const gchar *t = g_variant_get_string(value, nullptr);
        checkable = t != nullptr && t[0] != '\0';
      } else if (g_strcmp0(key, "toggle-state") == 0 &&
                 g_variant_is_of_type(value, G_VARIANT_TYPE_INT32)) {
        toggleState = g_variant_get_int32(value);
      }
    }
    g_variant_iter_free(props);
    if (checkable) item.checked = toggleState == 1 ? 1 : 0;

    if (!skipSelf && visible) items.push_back(item);
    const int32_t childParent = skipSelf ? -1 : id;

    GVariant *wrap = nullptr;
    while ((wrap = g_variant_iter_next_value(kids))) {
      GVariant *child = g_variant_get_variant(wrap);
      if (child != nullptr) {
        if (visible || skipSelf) parseLayoutNode(child, childParent, false);
        g_variant_unref(child);
      }
      g_variant_unref(wrap);
    }
    g_variant_iter_free(kids);
  }

  /// Full tree from the application, not libdbusmenu's cached one.
  bool fetchLayout()
  {
    if (conn == nullptr || openService.empty() || openPath.empty()) return false;
    GError *err = nullptr;
    GVariant *ret = g_dbus_connection_call_sync(
        conn, openService.c_str(), openPath.c_str(), "com.canonical.dbusmenu",
        "GetLayout",
        g_variant_new("(ii@as)", 0, -1, g_variant_new_strv(nullptr, 0)),
        G_VARIANT_TYPE("(u(ia{sv}av))"), G_DBUS_CALL_FLAGS_NONE, 2000, nullptr,
        &err);
    if (ret == nullptr) {
      if (err) g_error_free(err);
      return false;
    }
    GVariant *layout = nullptr;
    guint32 unusedRev = 0;
    g_variant_get(ret, "(u@(ia{sv}av))", &unusedRev, &layout);
    g_variant_unref(ret);
    if (layout == nullptr) return false;
    items.clear();
    parseLayoutNode(layout, -1, true);
    g_variant_unref(layout);
    mergeToggleProperties();
    return true;
  }

  bool hasChild(int32_t parentId) const
  {
    for (const Item &it : items) {
      if (it.parent == parentId) return true;
    }
    return false;
  }

  bool under(int32_t id, int32_t ancestor) const
  {
    while (id != -1) {
      if (id == ancestor) return true;
      int32_t next = -1;
      bool found = false;
      for (const Item &it : items) {
        if (it.id == id) {
          next = it.parent;
          found = true;
          break;
        }
      }
      if (!found || next == id) break;
      id = next;
    }
    return false;
  }

  void logLayout() const
  {
    std::cerr << "canvas: appmenu layout " << items.size() << " items";
    for (const Item &it : items) {
      if (it.parent == -1 && !it.label.empty()) std::cerr << " [" << it.label << "]";
    }
    std::cerr << "\n";
  }

  void rebuild()
  {
    dirty = false;
    ++revision;
    if (fetchLayout()) {
      if (debug()) logLayout();
      return;
    }
    items.clear();
    if (client == nullptr) return;
    DbusmenuMenuitem *root = dbusmenu_client_get_root(client);
    if (root == nullptr) {
      if (debug()) std::cerr << "canvas: appmenu layout: no root yet\n";
      return;
    }
    append(root, -1);
    mergeToggleProperties();
    if (debug() || items.empty()) logLayout();
  }

  /// Fill a submenu Chromium left empty, then any nested empty submenus
  /// under it so "Open Recent" is not a dead header.
  void fillSubmenu(int32_t itemId)
  {
    if (aboutToShowSync(itemId) && fetchLayout()) {
      for (int pass = 0; pass < 3; ++pass) {
        std::vector<int32_t> pending;
        for (const Item &it : items) {
          if (!it.submenu || hasChild(it.id)) continue;
          if (it.id == itemId || under(it.parent, itemId)) pending.push_back(it.id);
        }
        if (pending.empty()) break;
        for (int32_t id : pending) aboutToShowSync(id);
        fetchLayout();
      }
      dirty = false;
      ++revision;
      logLayout();
      return;
    }
    DbusmenuMenuitem *mi = find(itemId);
    if (mi == nullptr) return;
    dbusmenu_menuitem_send_about_to_show(mi, onAboutToShown, nullptr);
  }

  void sendEvent(int32_t itemId, const char *event)
  {
    if (conn == nullptr || openService.empty() || openPath.empty()) return;
    const guint32 ts = static_cast<guint32>(g_get_real_time() / 1000000);
    g_dbus_connection_call(
        conn, openService.c_str(), openPath.c_str(), "com.canonical.dbusmenu",
        "Event",
        g_variant_new("(isvu)", itemId, event,
                      g_variant_new_variant(g_variant_new_int32(0)), ts),
        nullptr, G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr, nullptr);
  }

  /// Fills in the check state, which the library does not fetch.
  ///
  /// `DbusmenuClient` asks for a fixed set of properties and only that set:
  ///
  ///     GetLayout(0, -1, ["type", "label", "visible", "enabled",
  ///                       "children-display", "accessible-desc"])
  ///
  /// `toggle-type` and `toggle-state` are not in it, are therefore never sent
  /// by the application, and are missing from every menu item the library
  /// hands back — there is no client API to widen the list. So a menu full of
  /// checkboxes came out with every box unticked: nm-applet's "Enable
  /// Networking" read as *off* while the network was plainly on.
  ///
  /// One extra round trip per layout change asks for exactly the two, which is
  /// cheap next to the layout itself and happens on the same thread for the
  /// same reason everything else here does.
  void mergeToggleProperties()
  {
    if (items.empty() || openService.empty() || openPath.empty()) return;
    if (conn == nullptr) {
      conn = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
      if (conn == nullptr) return;
    }

    GVariantBuilder ids;
    g_variant_builder_init(&ids, G_VARIANT_TYPE("ai"));
    for (const Item &it : items) g_variant_builder_add(&ids, "i", it.id);
    static const gchar *const wanted[] = {"toggle-type", "toggle-state",
                                          nullptr};

    GError *err = nullptr;
    GVariant *ret = g_dbus_connection_call_sync(
      conn, openService.c_str(), openPath.c_str(), "com.canonical.dbusmenu",
      "GetGroupProperties",
      g_variant_new("(@ai^as)", g_variant_builder_end(&ids), wanted),
      G_VARIANT_TYPE("(a(ia{sv}))"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr,
      &err);
    if (ret == nullptr) {
      // Not worth a word in the log: an application that answers the layout
      // and not this is drawing an unticked box, which is what it did before.
      if (err) g_error_free(err);
      return;
    }

    GVariantIter *rows = nullptr;
    g_variant_get(ret, "(a(ia{sv}))", &rows);
    gint32 id = 0;
    GVariantIter *props = nullptr;
    while (g_variant_iter_loop(rows, "(ia{sv})", &id, &props)) {
      const gchar *key = nullptr;
      GVariant *value = nullptr;
      bool checkable = false;
      int state = 0;
      while (g_variant_iter_loop(props, "{&sv}", &key, &value)) {
        if (g_strcmp0(key, "toggle-type") == 0 &&
            g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
          const gchar *type = g_variant_get_string(value, nullptr);
          checkable = type != nullptr && *type != '\0';
        } else if (g_strcmp0(key, "toggle-state") == 0 &&
                   g_variant_is_of_type(value, G_VARIANT_TYPE_INT32)) {
          state = g_variant_get_int32(value);
        }
      }
      if (!checkable) continue;
      for (Item &it : items) {
        if (it.id == id) {
          // Anything but 1 is unchecked, including DBusMenu's "indeterminate"
          // — a tri-state box is not something this menu can draw.
          it.checked = state == DBUSMENU_MENUITEM_TOGGLE_STATE_CHECKED ? 1 : 0;
          break;
        }
      }
    }
    g_variant_iter_free(rows);
    g_variant_unref(ret);
  }

  /// Depth-first, parents before children, which is the order a menu is drawn
  /// in and the order that lets a consumer build a tree in one pass.
  void append(DbusmenuMenuitem *parent, int32_t parentId)
  {
    GList *children = dbusmenu_menuitem_get_children(parent);
    for (GList *node = children; node != nullptr; node = node->next) {
      auto *mi = static_cast<DbusmenuMenuitem *>(node->data);
      if (mi == nullptr) continue;
      // An application hides an item rather than removing it — a "Paste" with
      // nothing on the clipboard — and a hidden item drawn anyway is a menu
      // entry the app believes it took away.
      if (!dbusmenu_menuitem_property_get_bool(mi, DBUSMENU_MENUITEM_PROP_VISIBLE)
          && dbusmenu_menuitem_property_get_variant(
               mi, DBUSMENU_MENUITEM_PROP_VISIBLE) != nullptr) {
        continue;
      }

      Item item;
      item.id = dbusmenu_menuitem_get_id(mi);
      item.parent = parentId;
      item.label = withoutMnemonics(
        dbusmenu_menuitem_property_get(mi, DBUSMENU_MENUITEM_PROP_LABEL));
      const gchar *type =
        dbusmenu_menuitem_property_get(mi, DBUSMENU_MENUITEM_PROP_TYPE);
      item.separator = g_strcmp0(type, DBUSMENU_CLIENT_TYPES_SEPARATOR) == 0;
      // Absent means enabled: the property is only sent when it is false, so
      // reading a missing one as "disabled" greys out entire menus.
      item.enabled =
        dbusmenu_menuitem_property_get_variant(
          mi, DBUSMENU_MENUITEM_PROP_ENABLED) == nullptr ||
        dbusmenu_menuitem_property_get_bool(mi, DBUSMENU_MENUITEM_PROP_ENABLED);

      const gchar *display = dbusmenu_menuitem_property_get(
        mi, DBUSMENU_MENUITEM_PROP_CHILD_DISPLAY);
      item.submenu =
        g_strcmp0(display, DBUSMENU_MENUITEM_CHILD_DISPLAY_SUBMENU) == 0;

      const gchar *toggle =
        dbusmenu_menuitem_property_get(mi, DBUSMENU_MENUITEM_PROP_TOGGLE_TYPE);
      // Almost always null — see `mergeToggleProperties`, which is where the
      // check state actually comes from. Read here anyway for the day the
      // library learns to fetch it, and because a menu item that carries the
      // property already should not need a second call to be believed.
      if (toggle != nullptr && *toggle != '\0') {
        item.checked = dbusmenu_menuitem_property_get_int(
                         mi, DBUSMENU_MENUITEM_PROP_TOGGLE_STATE) ==
                           DBUSMENU_MENUITEM_TOGGLE_STATE_CHECKED
                         ? 1
                         : 0;
      }

      items.push_back(item);
      append(mi, item.id);
    }
  }

  /// The item with this id, resolved against the tree that exists *now*.
  ///
  /// Deliberately a walk rather than a map built with the snapshot. The items
  /// belong to the `DbusmenuClient`, which frees them whenever the application
  /// changes its menu — so a map of raw pointers is correct only until the
  /// next layout update, and a click landing in that window used a freed
  /// object. It crashed inside libdbusmenu, which is the polite version of
  /// what a use-after-free usually does.
  ///
  /// Refcounting the entries would have fixed the crash and kept a subtler
  /// bug: an item detached from its client is not a menu item any more, and
  /// sending it an event asks a question about a menu that no longer exists.
  /// Walking is O(items) on a structure with tens of entries, and it happens
  /// once per click.
  DbusmenuMenuitem *find(int32_t id) const
  {
    if (client == nullptr) return nullptr;
    DbusmenuMenuitem *root = dbusmenu_client_get_root(client);
    return root == nullptr ? nullptr : findIn(root, id);
  }

  static DbusmenuMenuitem *findIn(DbusmenuMenuitem *parent, int32_t id)
  {
    for (GList *node = dbusmenu_menuitem_get_children(parent); node != nullptr;
         node = node->next) {
      auto *mi = static_cast<DbusmenuMenuitem *>(node->data);
      if (mi == nullptr) continue;
      if (dbusmenu_menuitem_get_id(mi) == id) return mi;
      if (DbusmenuMenuitem *found = findIn(mi, id)) return found;
    }
    return nullptr;
  }

  /// Somewhere for libdbusmenu to call back into. Nothing here wants the
  /// reply — the layout update that follows is the answer — but the client
  /// implementation is not obliged to tolerate a null one, and a crash inside
  /// a library is a poor way to find out which way it went.
  static void onAboutToShown(DbusmenuMenuitem * /*mi*/, gpointer /*data*/) {}
};

MenuImportHost::MenuImportHost() : impl_(std::make_unique<Impl>()) {}

MenuImportHost::~MenuImportHost()
{
  if (!impl_) return;
  impl_->closeClient();
  if (impl_->objectToken != 0 && impl_->conn != nullptr) {
    g_dbus_connection_unregister_object(impl_->conn, impl_->objectToken);
  }
  if (impl_->nameToken != 0) g_bus_unown_name(impl_->nameToken);
  if (impl_->conn != nullptr) g_object_unref(impl_->conn);
}

bool MenuImportHost::startImportOnly()
{
  // Nothing to do but say yes. `DbusmenuClient` opens its own connection to
  // the service it is pointed at, so an importer that serves no registrar
  // needs neither a bus handle of its own nor a name — and claiming one would
  // take it from the panel's real registrar, which is the same process.
  return true;
}

bool MenuImportHost::start()
{
  if (impl_->nameToken != 0) return impl_->nameAcquired;

  GError *err = nullptr;
  impl_->conn = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
  if (impl_->conn == nullptr) {
    std::cerr << "canvas: no session bus for the menu registrar: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    return false;
  }

  GDBusNodeInfo *info = g_dbus_node_info_new_for_xml(kIntrospection, &err);
  if (info == nullptr) {
    std::cerr << "canvas: registrar introspection failed: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    return false;
  }

  static const GDBusInterfaceVTable vtable = {Impl::onMethodCall, nullptr,
                                              nullptr, {nullptr}};
  impl_->objectToken = g_dbus_connection_register_object(
    impl_->conn, kRegistrarPath, info->interfaces[0], &vtable, impl_.get(),
    nullptr, &err);
  g_dbus_node_info_unref(info);
  if (impl_->objectToken == 0) {
    std::cerr << "canvas: could not export the registrar object: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    return false;
  }

  // Synchronously, because the answer decides what this panel *is* — a global
  // menu host or a strip with a clock — and the caller has to be told which
  // before it draws anything. `DO_NOT_QUEUE` is the whole point: queueing
  // would leave us waiting for a KDE session to exit.
  auto claim = [&](const char *name) {
    GVariant *ret = g_dbus_connection_call_sync(
      impl_->conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "RequestName",
      g_variant_new("(su)", name,
                    static_cast<guint32>(G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE)),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, nullptr);
    if (ret == nullptr) return false;
    guint32 result = 0;
    g_variant_get(ret, "(u)", &result);
    g_variant_unref(ret);
    // 1 = primary owner, 4 = already the owner.
    return result == 1 || result == 4;
  };

  if (claim(kCanonicalName)) {
    impl_->busName = kCanonicalName;
    impl_->nameAcquired = true;
  } else if (claim(kLavaName)) {
    impl_->busName = kLavaName;
    impl_->nameAcquired = true;
    std::cerr << "canvas: " << kCanonicalName
              << " is owned by another panel; serving " << kLavaName
              << " instead (LavaUI apps will find it; foreign apps use "
                 "kde-appmenu)\n";
  } else {
    // Still useful: the panel can import menus whose addresses arrive over
    // the control plane from org_kde_kwin_appmenu, without owning a registrar.
    std::cerr << "canvas: no registrar name available; importing only via "
                 "explicit menu addresses (kde-appmenu)\n";
  }

  // Bus connection is enough to open a DbusmenuClient; registrar ownership is
  // only required for Lava clients that RegisterWindow under a surface id.
  return true;
}

const std::string &MenuImportHost::busName() const { return impl_->busName; }

void MenuImportHost::setActiveWindow(uint32_t windowId,
                                     std::string menuService,
                                     std::string menuObjectPath,
                                     uint32_t pid)
{
  if (impl_->active == windowId && impl_->activePid == pid &&
      impl_->activeService == menuService &&
      impl_->activePath == menuObjectPath) {
    return;
  }
  impl_->active = windowId;
  impl_->activePid = pid;
  impl_->activeService = std::move(menuService);
  impl_->activePath = std::move(menuObjectPath);
  impl_->openClient();
}

uint32_t MenuImportHost::activeWindow() const { return impl_->active; }

bool MenuImportHost::hasMenu() const { return !impl_->items.empty(); }

void MenuImportHost::poll()
{
  // Bounded, for the reason `AppMenuHost::poll` is bounded: a source that
  // always has work must not be able to hold the frame loop.
  for (int i = 0; i < 64; ++i) {
    if (!g_main_context_iteration(nullptr, FALSE)) break;
  }
  if (impl_->dirty) impl_->rebuild();
}

uint64_t MenuImportHost::revision() const { return impl_->revision; }

size_t MenuImportHost::itemCount() const { return impl_->items.size(); }

int32_t MenuImportHost::itemId(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].id : 0;
}

int32_t MenuImportHost::itemParent(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].parent : -1;
}

std::string MenuImportHost::itemLabel(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].label : std::string{};
}

bool MenuImportHost::itemEnabled(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].enabled : false;
}

bool MenuImportHost::itemSeparator(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].separator : false;
}

bool MenuImportHost::itemHasSubmenu(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].submenu : false;
}

int MenuImportHost::itemChecked(size_t index) const
{
  return index < impl_->items.size() ? impl_->items[index].checked : -1;
}

void MenuImportHost::activate(int32_t itemId)
{
  DbusmenuMenuitem *mi = impl_->find(itemId);
  if (mi != nullptr) {
    // `handle_event` on a client-side item is what puts an `Event` on the bus;
    // the application on the other end runs its handler and, if the menu changed
    // as a result, sends a layout update back.
    dbusmenu_menuitem_handle_event(
        mi, DBUSMENU_MENUITEM_EVENT_ACTIVATED, g_variant_new_int32(0),
        static_cast<guint>(g_get_real_time() / 1000000));
    return;
  }
  // Children fetched via GetLayout after AboutToShow are not in the
  // DbusmenuClient tree (Chromium never told it to refetch). Event still
  // works; the id is the application's.
  impl_->sendEvent(itemId, "clicked");
}

void MenuImportHost::aboutToShow(int32_t itemId)
{
  impl_->fillSubmenu(itemId);
}

#else // !CANVAS_HAVE_DBUSMENU

struct MenuImportHost::Impl {
  std::string busName;
};

MenuImportHost::MenuImportHost() : impl_(std::make_unique<Impl>()) {}
MenuImportHost::~MenuImportHost() = default;

bool MenuImportHost::start() { return false; }
bool MenuImportHost::startImportOnly() { return false; }
const std::string &MenuImportHost::busName() const { return impl_->busName; }
void MenuImportHost::setActiveWindow(uint32_t, std::string, std::string,
                                     uint32_t) {}
uint32_t MenuImportHost::activeWindow() const { return 0; }
bool MenuImportHost::hasMenu() const { return false; }
void MenuImportHost::poll() {}
uint64_t MenuImportHost::revision() const { return 0; }
size_t MenuImportHost::itemCount() const { return 0; }
int32_t MenuImportHost::itemId(size_t) const { return 0; }
int32_t MenuImportHost::itemParent(size_t) const { return -1; }
std::string MenuImportHost::itemLabel(size_t) const { return {}; }
bool MenuImportHost::itemEnabled(size_t) const { return false; }
bool MenuImportHost::itemSeparator(size_t) const { return false; }
bool MenuImportHost::itemHasSubmenu(size_t) const { return false; }
int MenuImportHost::itemChecked(size_t) const { return -1; }
void MenuImportHost::activate(int32_t) {}
void MenuImportHost::aboutToShow(int32_t) {}

#endif

} // namespace canvas
