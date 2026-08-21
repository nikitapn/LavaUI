#pragma once

// The panel's half of the global menu: own the AppMenu registrar, and read the
// menu an application exported over DBusMenu.
//
// `AppMenuHost` next door is the other end — what an *application* does to
// publish its menu. This is what a *panel* does to show one, and the two are
// deliberately separate classes: an app that exported a menu has no business
// reading other apps' menus, and a panel drawing them has none to export.
//
// Optional at build time (CANVAS_HAVE_DBUSMENU). Stubbed when unavailable, in
// which case a panel finds no menu and draws nothing, which is the same thing
// it does when no application has one.

#include <cstdint>
#include <memory>
#include <string>

namespace canvas {

/// Serves the AppMenu registrar and imports the active window's menu.
///
/// Two jobs because the protocol splits them across two connections and one
/// process has to hold both: applications call *us* to say "my menu lives at
/// this object path", and then we call *them* to read what is in it. A panel
/// that only did the first would know a menu exists and nothing about it.
///
/// Single-threaded: everything runs on whichever thread calls `poll`, which is
/// the frame loop. GLib's default main context is what carries the traffic, so
/// a frame that never polls is a menu that never updates — and, worse, an
/// application blocked on a `GetLayout` we are not answering.
class MenuImportHost {
public:
  MenuImportHost();
  ~MenuImportHost();

  MenuImportHost(const MenuImportHost &) = delete;
  MenuImportHost &operator=(const MenuImportHost &) = delete;

  /// Claims a registrar name and starts serving. False if there is no session
  /// bus or no name left to own.
  ///
  /// Tries `com.canonical.AppMenu.Registrar` first, because that is the name
  /// every Qt and GTK application already looks for — owning it means their
  /// menus arrive here too, with nothing to change on their side. Inside a
  /// desktop that already has a registrar (a KDE session, say) that name is
  /// taken, and taking it away from the running panel would break the session
  /// we are a guest in; there we fall back to `org.lavaui.AppMenu.Registrar`,
  /// which LavaUI applications look for first for exactly this reason.
  bool start();

  /// Start the importing half only: no registrar name, no exported object.
  ///
  /// For menus whose address arrives some other way and that nobody registers
  /// — a tray item's `Menu` property is the one that matters, and a panel
  /// needs a second importer for it precisely because the first is busy
  /// holding the focused window's menu.
  bool startImportOnly();

  /// The name actually owned, or empty. Worth surfacing: which one it is
  /// decides whether foreign applications can find us.
  const std::string &busName() const;

  /// Whose menu to import. 0 for none — the desktop is focused, or the focused
  /// window never registered one.
  ///
  /// When `menuService` and `menuObjectPath` are non-empty they are the DBus
  /// coordinates of the menu (KDE Wayland AppMenu / `org_kde_kwin_appmenu`).
  /// The panel opens that object directly. When they are empty, falls back to
  /// the AppMenu registrar entry for `windowId` — what Lava clients use with
  /// their surface id — and if that misses, to a registrar entry whose DBus
  /// sender has `pid`. Qt5 on Wayland registers as window id `1`.
  void setActiveWindow(uint32_t windowId, std::string menuService = {},
                       std::string menuObjectPath = {}, uint32_t pid = 0);
  uint32_t activeWindow() const;

  /// Whether the active window has a menu with anything in it.
  bool hasMenu() const;

  /// Iterate GLib once, without blocking. Call every frame.
  ///
  /// Two directions at once: it answers applications registering with us, and
  /// it delivers the layouts we asked them for. Skipping it stalls both.
  void poll();

  /// Bumped whenever the imported menu changes — a new active window, a layout
  /// update, a registration arriving late. A panel rebuilds its view when this
  /// moves rather than diffing the items itself.
  uint64_t revision() const;

  // ─── The imported menu, flattened ────────────────────────────────────────
  //
  // Index-addressed rather than handed over as a tree, because the consumer is
  // Swift across a C++ interop boundary and a flat array of scalars is the one
  // shape that crosses it without a translation layer on both sides. Parents
  // are named by `itemId`, which is DBusMenu's own id — the same number an
  // activation goes back out with.

  size_t itemCount() const;
  /// DBusMenu's id for this item. Stable while the layout is.
  int32_t itemId(size_t index) const;
  /// The `itemId` of the item this one sits under, or -1 at the top level.
  int32_t itemParent(size_t index) const;
  std::string itemLabel(size_t index) const;
  bool itemEnabled(size_t index) const;
  bool itemSeparator(size_t index) const;
  /// Whether this item opens a submenu. True with no children imported yet
  /// means the application has not been asked for them — see `aboutToShow`.
  bool itemHasSubmenu(size_t index) const;
  /// -1 not checkable, 0 unchecked, 1 checked.
  int itemChecked(size_t index) const;

  /// "The user chose this one." Sends DBusMenu's `clicked` event, which is
  /// what runs the handler in the application that owns the menu.
  void activate(int32_t itemId);

  /// "A submenu is about to open." Applications are allowed to fill a submenu
  /// only when asked, so a menu opened without this can legitimately be empty.
  void aboutToShow(int32_t itemId);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
