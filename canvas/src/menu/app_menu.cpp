#include "menu/app_menu.hpp"

#include <iostream>
#include <mutex>
#include <queue>
#include <vector>

#if defined(CANVAS_HAVE_DBUSMENU)
#include <gio/gio.h>
#include <libdbusmenu-glib/dbusmenu-glib.h>
// Unblock glfwWaitEvents when the panel activates an item.
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#endif

namespace canvas {

#if defined(CANVAS_HAVE_DBUSMENU)

namespace {

constexpr const char *kRegistrarDest = "com.canonical.AppMenu.Registrar";
constexpr const char *kRegistrarPath = "/com/canonical/AppMenu/Registrar";
constexpr const char *kRegistrarIface = "com.canonical.AppMenu.Registrar";
constexpr const char *kLavaIdKey = "lava-menu-id";

bool nameHasOwner(GDBusConnection *conn, const char *name)
{
  GError *err = nullptr;
  GVariant *ret = g_dbus_connection_call_sync(
    conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "NameHasOwner", g_variant_new("(s)", name), G_VARIANT_TYPE("(b)"),
    G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &err);
  if (!ret) {
    if (err) g_error_free(err);
    return false;
  }
  gboolean owned = FALSE;
  g_variant_get(ret, "(b)", &owned);
  g_variant_unref(ret);
  return owned;
}

} // namespace

struct AppMenuHost::Impl {
  DbusmenuServer *server = nullptr;
  DbusmenuMenuitem *root = nullptr;
  std::vector<DbusmenuMenuitem *> stack;
  uint32_t xid = 0;
  std::string objectPath;
  bool registered = false;

  std::mutex activationMutex;
  std::queue<std::string> activations;

  static void onItemActivated(DbusmenuMenuitem *mi, guint /*timestamp*/,
                              gpointer userData)
  {
    auto *self = static_cast<Impl *>(userData);
    const gchar *id =
      static_cast<const gchar *>(g_object_get_data(G_OBJECT(mi), kLavaIdKey));
    if (!id || !id[0]) return;
    {
      std::lock_guard<std::mutex> lock(self->activationMutex);
      self->activations.push(id);
    }
    // Frame loop may be blocked in glfwWaitEvents; wake it so poll() runs.
    glfwPostEmptyEvent();
  }

  void queueActivation(const std::string &id)
  {
    std::lock_guard<std::mutex> lock(activationMutex);
    activations.push(id);
  }

  void clearTree()
  {
    stack.clear();
    if (root) {
      g_object_unref(root);
      root = nullptr;
    }
  }

  DbusmenuMenuitem *currentParent()
  {
    if (!stack.empty()) return stack.back();
    return root;
  }

  void tagId(DbusmenuMenuitem *mi, const std::string &id)
  {
    if (id.empty()) return;
    g_object_set_data_full(G_OBJECT(mi), kLavaIdKey, g_strdup(id.c_str()), g_free);
  }

  void wireActivation(DbusmenuMenuitem *mi)
  {
    g_signal_connect(G_OBJECT(mi), DBUSMENU_MENUITEM_SIGNAL_ITEM_ACTIVATED,
                     G_CALLBACK(onItemActivated), this);
  }
};

AppMenuHost::AppMenuHost() : impl_(std::make_unique<Impl>()) {}

AppMenuHost::~AppMenuHost() { detach(); }

bool AppMenuHost::registrarAvailable()
{
  GError *err = nullptr;
  GDBusConnection *conn =
    g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
  if (!conn) {
    if (err) g_error_free(err);
    return false;
  }
  const bool ok = nameHasOwner(conn, kRegistrarDest);
  g_object_unref(conn);
  return ok;
}

bool AppMenuHost::attach(uint32_t x11WindowId)
{
  detach();
  if (x11WindowId == 0) return false;
  if (!registrarAvailable()) return false;

  impl_->xid = x11WindowId;
  impl_->objectPath = "/com/canonical/menu/" + std::to_string(x11WindowId);

  impl_->server = dbusmenu_server_new(impl_->objectPath.c_str());
  if (!impl_->server) {
    std::cerr << "canvas: dbusmenu_server_new failed\n";
    detach();
    return false;
  }

  // Empty root until first commitUpdate.
  impl_->root = dbusmenu_menuitem_new();
  dbusmenu_menuitem_set_root(impl_->root, TRUE);
  dbusmenu_server_set_root(impl_->server, impl_->root);

  GError *err = nullptr;
  GDBusConnection *conn =
    g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
  if (!conn) {
    std::cerr << "canvas: session bus unavailable for AppMenu: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    detach();
    return false;
  }

  GVariant *ret = g_dbus_connection_call_sync(
    conn, kRegistrarDest, kRegistrarPath, kRegistrarIface, "RegisterWindow",
    g_variant_new("(uo)", static_cast<guint32>(x11WindowId),
                  impl_->objectPath.c_str()),
    nullptr, G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, &err);
  g_object_unref(conn);

  if (!ret) {
    std::cerr << "canvas: AppMenu RegisterWindow failed: "
              << (err ? err->message : "?") << "\n";
    if (err) g_error_free(err);
    detach();
    return false;
  }
  g_variant_unref(ret);
  impl_->registered = true;
  std::cerr << "canvas: AppMenu registered window " << x11WindowId
            << " → " << impl_->objectPath << "\n";
  return true;
}

void AppMenuHost::detach()
{
  if (!impl_) return;

  if (impl_->registered && impl_->xid != 0) {
    GError *err = nullptr;
    GDBusConnection *conn =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &err);
    if (conn) {
      GVariant *ret = g_dbus_connection_call_sync(
        conn, kRegistrarDest, kRegistrarPath, kRegistrarIface, "UnregisterWindow",
        g_variant_new("(u)", static_cast<guint32>(impl_->xid)),
        nullptr, G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &err);
      if (ret) g_variant_unref(ret);
      else if (err) g_error_free(err);
      g_object_unref(conn);
    } else if (err) {
      g_error_free(err);
    }
    impl_->registered = false;
  }

  impl_->clearTree();
  if (impl_->server) {
    g_object_unref(impl_->server);
    impl_->server = nullptr;
  }
  impl_->xid = 0;
  impl_->objectPath.clear();
  {
    std::lock_guard<std::mutex> lock(impl_->activationMutex);
    while (!impl_->activations.empty()) impl_->activations.pop();
  }
}

bool AppMenuHost::isAttached() const
{
  return impl_ && impl_->registered && impl_->server;
}

void AppMenuHost::poll()
{
  // Non-blocking dispatch of the default GLib context (GDBus + dbusmenu).
  // Cap iterations so a misbehaving source cannot spin the UI thread forever;
  // the frame loop calls us again within dbusPumpInterval.
  for (int i = 0; i < 64; ++i) {
    if (!g_main_context_iteration(nullptr, FALSE)) break;
  }
}

void AppMenuHost::beginUpdate()
{
  if (!impl_) return;
  impl_->clearTree();
  impl_->root = dbusmenu_menuitem_new();
  dbusmenu_menuitem_set_root(impl_->root, TRUE);
  impl_->stack.clear();
}

void AppMenuHost::beginMenu(const std::string &id, const std::string &title)
{
  if (!impl_ || !impl_->root) return;
  DbusmenuMenuitem *mi = dbusmenu_menuitem_new();
  dbusmenu_menuitem_property_set(mi, DBUSMENU_MENUITEM_PROP_LABEL, title.c_str());
  dbusmenu_menuitem_property_set_bool(mi, DBUSMENU_MENUITEM_PROP_ENABLED, TRUE);
  impl_->tagId(mi, id);
  dbusmenu_menuitem_child_append(impl_->currentParent(), mi);
  impl_->stack.push_back(mi);
}

void AppMenuHost::endMenu()
{
  if (!impl_ || impl_->stack.empty()) return;
  impl_->stack.pop_back();
}

void AppMenuHost::addItem(const std::string &id, const std::string &title,
                          bool enabled, int checked)
{
  if (!impl_ || !impl_->root) return;
  DbusmenuMenuitem *mi = dbusmenu_menuitem_new();
  dbusmenu_menuitem_property_set(mi, DBUSMENU_MENUITEM_PROP_LABEL, title.c_str());
  dbusmenu_menuitem_property_set_bool(mi, DBUSMENU_MENUITEM_PROP_ENABLED, enabled);
  if (checked >= 0) {
    dbusmenu_menuitem_property_set(mi, DBUSMENU_MENUITEM_PROP_TOGGLE_TYPE,
                                  DBUSMENU_MENUITEM_TOGGLE_CHECK);
    dbusmenu_menuitem_property_set_int(
      mi, DBUSMENU_MENUITEM_PROP_TOGGLE_STATE,
      checked ? DBUSMENU_MENUITEM_TOGGLE_STATE_CHECKED
              : DBUSMENU_MENUITEM_TOGGLE_STATE_UNCHECKED);
  }
  impl_->tagId(mi, id);
  impl_->wireActivation(mi);
  dbusmenu_menuitem_child_append(impl_->currentParent(), mi);
}

void AppMenuHost::addSeparator()
{
  if (!impl_ || !impl_->root) return;
  DbusmenuMenuitem *mi = dbusmenu_menuitem_new();
  dbusmenu_menuitem_property_set(mi, DBUSMENU_MENUITEM_PROP_TYPE,
                                DBUSMENU_CLIENT_TYPES_SEPARATOR);
  dbusmenu_menuitem_child_append(impl_->currentParent(), mi);
}

void AppMenuHost::commitUpdate()
{
  if (!impl_ || !impl_->server || !impl_->root) return;
  // stack should be empty; if not, callers mismatched begin/end — still publish.
  impl_->stack.clear();
  dbusmenu_server_set_root(impl_->server, impl_->root);
}

bool AppMenuHost::popActivation(std::string &outId)
{
  if (!impl_) return false;
  std::lock_guard<std::mutex> lock(impl_->activationMutex);
  if (impl_->activations.empty()) return false;
  outId = std::move(impl_->activations.front());
  impl_->activations.pop();
  return true;
}

#else // !CANVAS_HAVE_DBUSMENU

struct AppMenuHost::Impl {};

AppMenuHost::AppMenuHost() : impl_(std::make_unique<Impl>()) {}
AppMenuHost::~AppMenuHost() = default;

bool AppMenuHost::registrarAvailable() { return false; }
bool AppMenuHost::attach(uint32_t) { return false; }
void AppMenuHost::detach() {}
bool AppMenuHost::isAttached() const { return false; }
void AppMenuHost::poll() {}
void AppMenuHost::beginUpdate() {}
void AppMenuHost::beginMenu(const std::string &, const std::string &) {}
void AppMenuHost::endMenu() {}
void AppMenuHost::addItem(const std::string &, const std::string &, bool, int) {}
void AppMenuHost::addSeparator() {}
void AppMenuHost::commitUpdate() {}
bool AppMenuHost::popActivation(std::string &) { return false; }

#endif

} // namespace canvas
