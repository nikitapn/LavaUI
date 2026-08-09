#include "menu/menu_import.hpp"

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
  };

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
  DbusmenuClient *client = nullptr;
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
      self->windows[windowId] = Registration{sender ? sender : "", path ? path : ""};
      self->emitRegistered(windowId, sender ? sender : "", path ? path : "");
      // The window this arrives for is often the one already focused: an
      // application registers its menu a moment after its window appears, and
      // by then the panel has long since been told what is active.
      if (windowId == self->active) self->openClient();
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }
    if (g_strcmp0(method, "UnregisterWindow") == 0) {
      guint32 windowId = 0;
      g_variant_get(params, "(u)", &windowId);
      self->windows.erase(windowId);
      self->emitUnregistered(windowId);
      if (windowId == self->active) self->closeClient();
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
    dirty = false;
    ++revision;
  }

  void openClient()
  {
    closeClient();
    auto it = windows.find(active);
    if (active == 0 || it == windows.end()) return;

    client = dbusmenu_client_new(it->second.service.c_str(),
                                 it->second.objectPath.c_str());
    if (client == nullptr) {
      std::cerr << "canvas: dbusmenu client for window " << active
                << " could not be created\n";
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

  void rebuild()
  {
    items.clear();
    dirty = false;
    ++revision;
    if (client == nullptr) return;
    DbusmenuMenuitem *root = dbusmenu_client_get_root(client);
    if (root == nullptr) return;
    append(root, -1);
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
  } else if (claim(kLavaName)) {
    impl_->busName = kLavaName;
    std::cerr << "canvas: " << kCanonicalName
              << " is owned by another panel; serving " << kLavaName
              << " instead (LavaUI apps will find it; foreign apps will not)\n";
  } else {
    std::cerr << "canvas: no registrar name available\n";
    return false;
  }

  impl_->nameAcquired = true;
  return true;
}

const std::string &MenuImportHost::busName() const { return impl_->busName; }

void MenuImportHost::setActiveWindow(uint32_t windowId)
{
  if (impl_->active == windowId) return;
  impl_->active = windowId;
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
  if (mi == nullptr) return;
  // `handle_event` on a client-side item is what puts an `Event` on the bus;
  // the application on the other end runs its handler and, if the menu changed
  // as a result, sends a layout update back.
  dbusmenu_menuitem_handle_event(mi, DBUSMENU_MENUITEM_EVENT_ACTIVATED,
                                 g_variant_new_int32(0),
                                 static_cast<guint>(g_get_real_time() / 1000000));
}

void MenuImportHost::aboutToShow(int32_t itemId)
{
  DbusmenuMenuitem *mi = impl_->find(itemId);
  if (mi == nullptr) return;
  // Fire and forget: the reply is a "you should re-read this" that arrives as
  // a layout update anyway, which `poll` is already watching for.
  dbusmenu_menuitem_send_about_to_show(mi, Impl::onAboutToShown, nullptr);
}

#else // !CANVAS_HAVE_DBUSMENU

struct MenuImportHost::Impl {
  std::string busName;
};

MenuImportHost::MenuImportHost() : impl_(std::make_unique<Impl>()) {}
MenuImportHost::~MenuImportHost() = default;

bool MenuImportHost::start() { return false; }
const std::string &MenuImportHost::busName() const { return impl_->busName; }
void MenuImportHost::setActiveWindow(uint32_t) {}
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
