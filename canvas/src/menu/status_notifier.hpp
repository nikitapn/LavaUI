#pragma once

// Status Notifier host: the panel owns `org.kde.StatusNotifierWatcher` and
// shows icons published by nm-applet, Blueman, pasystray, and anything else
// that speaks KDE StatusNotifierItem / freedesktop AppIndicator.
//
// Deliberately not Plasma/GNOME applet embedding — those run inside their
// shells. SNI is the interop layer every non-Plasma panel uses: the app owns
// its menu window; we only own the icon strip and the Activate/ContextMenu
// calls.
//
// Optional at build time with the same GIO stack as AppMenu (`CANVAS_HAVE_DBUSMENU`).
// Stubbed otherwise: the panel has no tray and nothing to show.

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace canvas {

/// Tracks StatusNotifierItems for a panel tray strip.
///
/// Two modes (same public API either way):
///
///   * **Own** — claim `org.kde.StatusNotifierWatcher` when free (a Lava-only
///     session). Applets register with us.
///   * **Follow** — when another desktop already owns the watcher (nested under
///     Plasma/GNOME, etc.), attach as a StatusNotifierHost, read
///     `RegisteredStatusNotifierItems`, and mirror register/unregister
///     signals. Icons still appear; we do not steal the session's tray.
///
/// Flat, index-addressed accessors match `MenuImportHost`. `poll` must run on
/// the frame loop so GLib delivers registration and property changes.
class StatusNotifierHost {
public:
  StatusNotifierHost();
  ~StatusNotifierHost();

  StatusNotifierHost(const StatusNotifierHost &) = delete;
  StatusNotifierHost &operator=(const StatusNotifierHost &) = delete;

  /// Start in own or follow mode. False only with no session bus / total fail.
  bool start();

  /// True when either mode is live and the tray can show items.
  bool isServing() const;

  /// Iterate GLib once. Call every frame while the panel is up.
  void poll();

  /// Bumped when the item list or any item's display data changes.
  uint64_t revision() const;

  size_t itemCount() const;

  /// Stable key for this item: `uniqueName/objectPath`. Used to activate.
  std::string itemKey(size_t index) const;
  /// Application-supplied id (`Id` property), often the desktop id.
  std::string itemId(size_t index) const;
  std::string itemTitle(size_t index) const;
  /// "Passive" / "Active" / "NeedsAttention".
  std::string itemStatus(size_t index) const;
  /// Theme icon name, may be empty when only a pixmap is provided.
  std::string itemIconName(size_t index) const;
  /// Absolute path to a resolved icon file, if one was found for `IconName`
  /// or under `IconThemePath`. Empty when only pixmap data is available.
  std::string itemIconPath(size_t index) const;
  /// Whether left-click should open the menu rather than Activate.
  bool itemIsMenu(size_t index) const;
  /// Whether this item exports a DBusMenu at all.
  bool itemHasMenu(size_t index) const;
  /// Whether a left click has nowhere to go but the menu: the item said
  /// `ItemIsMenu`, or it never implemented `Activate` — which is the ordinary
  /// case for anything built on libappindicator, nm-applet included.
  bool itemPrefersMenu(size_t index) const;

  /// Decoded RGBA8 icon pixels (may be empty). Network-order ARGB from the
  /// bus is converted here so Swift can `uploadImage` without byte-swapping.
  int itemIconWidth(size_t index) const;
  int itemIconHeight(size_t index) const;
  size_t itemIconRgbaSize(size_t index) const;
  /// Copies up to `cap` bytes into `out`. Returns bytes written.
  size_t itemIconRgbaCopy(size_t index, uint8_t *out, size_t cap) const;

  /// Left-click (or ItemIsMenu path). Coordinates are screen pixels; many
  /// clients ignore them.
  void activate(const std::string &key, int x, int y);
  /// Right-click / menu.
  void contextMenu(const std::string &key, int x, int y);
  void secondaryActivate(const std::string &key, int x, int y);
  void scroll(const std::string &key, int delta, const std::string &orientation);

  // ─── The open item's menu ────────────────────────────────────────────────
  //
  // An applet's menu is a DBusMenu like any other, so this is a
  // `MenuImportHost` in import-only mode rather than a second implementation
  // of the protocol. It lives here because the menu belongs to the item: it
  // opens with one, closes with it, and dies when the applet goes away.
  //
  // Same flat, index-addressed shape as the importer's own accessors, and the
  // ids are DBusMenu's, so a panel can turn both into the same menu model.

  /// Points the importer at `key`'s menu. False when the item has none, which
  /// is the caller's cue to fall back to `activate`.
  bool openMenu(const std::string &key);
  /// Drops the menu. The applet is told nothing — DBusMenu has no "closed"
  /// and none of them expect one.
  void closeMenu();
  /// Which item's menu is open, empty for none.
  const std::string &openMenuKey() const;
  /// Bumped when the open menu's layout changes, including when it first
  /// arrives — a menu is empty until the application answers.
  uint64_t menuRevision() const;

  size_t menuItemCount() const;
  int32_t menuItemId(size_t index) const;
  int32_t menuItemParent(size_t index) const;
  std::string menuItemLabel(size_t index) const;
  bool menuItemEnabled(size_t index) const;
  bool menuItemSeparator(size_t index) const;
  bool menuItemHasSubmenu(size_t index) const;
  int menuItemChecked(size_t index) const;
  void menuActivate(int32_t itemId);
  void menuAboutToShow(int32_t itemId);

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas
