#pragma once

// Linux global menu export (DBusMenu + com.canonical.AppMenu.Registrar).
// Optional at build time (CANVAS_HAVE_DBUSMENU). Stubbed when unavailable.
//
// Used by LavaUI MenuHost when Vala Panel / xfce appmenu / Plasma global menu
// is present. See docs/native-menus.md.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace canvas {

/// Session-bus AppMenu / DBusMenu host for one GLFW/X11 window.
class AppMenuHost {
public:
  AppMenuHost();
  ~AppMenuHost();

  AppMenuHost(const AppMenuHost &) = delete;
  AppMenuHost &operator=(const AppMenuHost &) = delete;

  /// True if libdbusmenu was linked and a Registrar name owner is on the bus.
  static bool registrarAvailable();

  /// Create DbusmenuServer, export object path, RegisterWindow(xid, path).
  /// Returns false if no X11 id, no registrar, or registration fails.
  bool attach(uint32_t x11WindowId);

  void detach();

  bool isAttached() const;

  /// Drain GLib main context (call once per frame after glfw poll).
  void poll();

  // ─── Incremental rebuild of the exported menu tree ─────────────────────
  //
  // beginUpdate → (beginMenu … items … endMenu)* → commitUpdate
  // Nested beginMenu/endMenu pairs build submenus.

  void beginUpdate();
  void beginMenu(const std::string &id, const std::string &title);
  void endMenu();
  /// checked: -1 = not checkable, 0 = unchecked, 1 = checked.
  void addItem(const std::string &id, const std::string &title, bool enabled,
               int checked);
  void addSeparator();
  void commitUpdate();

  /// Pop one activation queued by the panel (our MenuID string). Empty if none.
  bool popActivation(std::string &outId);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
