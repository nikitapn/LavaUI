#pragma once

// Server half of `org_kde_kwin_appmenu` (the KDE Wayland AppMenu protocol).
//
// A client exports its menu over DBus as `com.canonical.dbusmenu`, then tells
// the compositor *where* that object lives and *which* wl_surface it belongs
// to. Plasma's global menu and anything else that wants to draw a foreign
// window's menu bar need both pieces: DBus has the tree, this protocol is how
// a focused surface is matched to it without an X11 window id.
//
// See `compositor/protocols/appmenu.xml` and https://wayland.app/protocols/kde-appmenu

#include <functional>
#include <string>

struct wl_display;
struct wlr_surface;

namespace lava {

/// DBus coordinates of a window's exported menu, or empty when the surface
/// has never sent `set_address` / has released its appmenu object.
struct AppMenuAddress {
  std::string service;
  std::string objectPath;

  bool empty() const { return service.empty() || objectPath.empty(); }
};

/// Global `org_kde_kwin_appmenu_manager` + per-surface appmenu objects.
class AppMenuManager {
 public:
  AppMenuManager();
  ~AppMenuManager();

  AppMenuManager(const AppMenuManager &) = delete;
  AppMenuManager &operator=(const AppMenuManager &) = delete;

  /// Advertise the global on `display`. Safe to call once.
  void init(wl_display *display);

  /// Fired on the Wayland loop when a surface's address is set, updated, or
  /// cleared. Used to re-tell a panel when Dolphin (etc.) registers after focus.
  using OnChanged = std::function<void(wlr_surface *surface)>;
  void setOnChanged(OnChanged cb);

  AppMenuAddress addressFor(wlr_surface *surface) const;

 private:
  struct Impl;
  Impl *impl_ = nullptr;
};

}  // namespace lava
