# Native application menus

Design for system-owned menu bars (macOS, Win32, Linux global menu) with a
LavaUI-shaped declarative API. Menus are **not** Yoga children and are **not**
in the draw list when the OS owns them. On Linux without a global-menu host
(Vala Panel appmenu, xfce4-panel applet, etc.), the same description is drawn
with the existing Vulkan path so the app always has a working menu bar.

## Goals

- Declarative Swift API in the spirit of LavaUI primitives (`Menu`, `MenuItem`,
  …), not an imperative “call CreateMenu” surface.
- Real system menus where the platform provides them:
  - **macOS** — AppKit `NSMenu` / main menu bar
  - **Windows** — Win32 `HMENU` + `SetMenu`
  - **Linux** — DBusMenu + AppMenu Registrar for Vala Panel / compatible panels
- **Linux fallback:** if no global-menu host is available, render an in-window
  menu bar with LavaUI + Vulkan (same IR, different host).
- No GTK/Qt widgets in the client area. Linux global menu uses D-Bus only
  (`libdbusmenu-glib` + GLib main context), not `GtkMenuBar` inside the GLFW
  window.
- Activations feed the same main-loop / invalidation path as pointer and key
  input.

## Non-goals (initial)

- Custom-drawn menu *items* with arbitrary LavaUI content inside an OS menu
  (macOS `NSMenuItem.view` is a later option).
- Full Wayland global-menu parity (Registrar is X11-window-id centric; see
  below).
- Replacing in-canvas dropdowns (`Overlay` comboboxes, color pickers). Those
  stay app-drawn; this doc is about **application command menus**.

## Precedent in the repo

| Piece | Lesson |
|---|---|
| `FileDialog` | Clean Swift API, platform backend, no Yoga, no draw list |
| `Overlay` | In-app popup geometry, paint-after-tree, hit-test first |
| `LavaApp.menuH` | Already reserved client offset for a bar (currently `0`) |
| `window_platform.cpp` | Native handles via `glfwGetX11Window` / Win32 / future Cocoa |

Menus are the **retained, evented** cousin of `FileDialog`: long-lived,
reconciled when app state changes, callback-driven rather than modal-blocking.

## Public API sketch

Menus are declared at the **app / window** boundary, not nested arbitrarily
inside arbitrary view bodies. The bar is process-global (macOS), window chrome
(Windows), or panel-global (Linux DBusMenu) — layout ownership belongs next to
`LavaApp`, not next to a random `VStack`.

```swift
LavaApp.run(
    editor: editor,
    menu: {
        MenuBar {
            Menu("File") {
                MenuItem("Open…", shortcut: .init(.o, .primary)) { open() }
                MenuItem("Save", shortcut: .init(.s, .primary), isEnabled: canSave) {
                    save()
                }
                MenuSeparator()
                MenuItem("Quit", shortcut: .init(.q, .primary)) { quit() }
            }
            Menu("Edit") {
                MenuItem("Copy", shortcut: .init(.c, .primary)) { copy() }
            }
        }
    },
    makeRoot: { RootView() }
)
```

Context menus (later) attach to views:

```swift
row.contextMenu {
    MenuItem("Delete") { delete(row.id) }
}
```

Those still share the same IR and hosts; only placement differs (popup at
pointer vs menubar).

### Types

```text
MenuBar { menus… }     // top-level container
Menu(title) { items… } // one top-level title ("File")
MenuItem(title, …)     // leaf command
MenuSeparator()
// later: MenuToggle, nested Menu as submenu, MenuRadioGroup
```

These can implement `View` / builder DSL for ergonomics (`Body == Never`) but
**must not** enter the Yoga tree as normal primitives. They produce a
`MenuModel` IR consumed by a `MenuHost`.

## Intermediate representation

Platform code never sees View types. It sees a pure value tree plus a side
table of actions:

```swift
struct MenuModel: Equatable {
    var menus: [MenuNode]
}

struct MenuNode: Equatable, Identifiable {
    var id: MenuID
    var title: String
    var items: [MenuEntry]
}

enum MenuEntry: Equatable {
    case item(MenuItemModel)
    case separator
    case submenu(MenuNode)
}

struct MenuItemModel: Equatable {
    var id: MenuID
    var title: String
    var isEnabled: Bool
    var isChecked: Bool?
    var shortcut: KeyShortcut?
}

// Actions live outside Equatable structure:
// [MenuID: () -> Void]
```

**Reconcile:** each invalidation rebuilds model + action map from the
declarative closure. Diff against the last applied model. If structure or
labels/flags changed, call `host.apply(model)`. Activations look up `MenuID`
in the action map on the main loop.

Full menubar rebuilds are cheap; micro-diffing OS items is an optional later
optimization.

## Platform hosts

```text
                    MenuModel + action map
                            │
                     ┌──────┴──────┐
                     │  MenuHost   │  (Swift: pick backend, own last model)
                     └──────┬──────┘
           ┌────────────────┼────────────────┐
           ▼                ▼                ▼
      CocoaHost         Win32Host       LinuxHost
      NSMenu            HMENU           ┌─────────────┐
                                        │ probe panel │
                                        └──────┬──────┘
                                    yes        │      no
                                     ▼         │       ▼
                              DBusMenuHost     │   VulkanMenuHost
                              + Registrar      │   (in-window bar)
```

### macOS — AppKit

- Build / replace `NSApp.mainMenu` from `MenuModel`.
- Key equivalents from `KeyShortcut` (Command/Option mapping).
- Item target is a small ObjC/Swift trampoline that enqueues `MenuID` into the
  LavaUI main queue and wakes the loop.
- GLFW: after window creation, use the Cocoa native handle; replace GLFW’s
  default menu rather than fighting it.

No client-area inset (`menuH = 0`).

### Windows — Win32

- `CreateMenu` / `CreatePopupMenu` / `InsertMenuItem` / `SetMenu(hwnd)` /
  `DrawMenuBar`.
- `hwnd = glfwGetWin32Window(...)`.
- Subclass WndProc (`SetWindowLongPtr(GWLP_WNDPROC)`): handle `WM_COMMAND`,
  forward everything else with `CallWindowProc`.
- Client area shrinks under the menu bar → measure bar height and set
  `menuH` so layout/hit-test/agent coords stay correct (existing `LavaApp`
  offset path).

### Linux — dual path

#### A. Global menu (preferred when available)

Vala Panel Application Menu (and xfce4-panel / mate-panel ports) consume the
Unity-style stack:

1. Export a menu tree over **DBusMenu** (`com.canonical.dbusmenu`) via
   `libdbusmenu-glib` (`DbusmenuServer` + `DbusmenuMenuitem`).
2. Register the window with **`com.canonical.AppMenu.Registrar`**:
   `RegisterWindow(xid, menu_object_path)` where `xid` is
   `glfwGetX11Window`.
3. The panel applet displays the menu; the app does not draw a bar.

Requirements at runtime:

- Session bus reachable
- Registrar name/owner present (appmenu-registrar / panel stack)
- X11 window (primary path; see Wayland note)

GLib: iterate `g_main_context_iteration(NULL, FALSE)` once per frame after
`glfwPollEvents` / `glfwWaitEvents` so D-Bus activations arrive without a
second thread. Soft-link dependencies; if libraries are missing at build or
load time, treat as “no global menu”.

#### B. Vulkan in-window bar (fallback)

Used when any of:

- Registrar not on the bus
- DBusMenu / GLib not linked or failed to init
- Wayland (or other backend) where window registration is unsupported
- Explicit env override (e.g. `LAVA_MENU=vulkan` for debugging)

Then the **same `MenuModel`** is shown as an in-window menu bar drawn by
LavaUI:

- A reserved strip at the top of the window (`menuH` = theme bar height)
- Top-level titles as hoverable cells
- Open menus as `Overlay` (or the same overlay machinery): paint above
  content, hit-test first, dismiss on outside click / Escape
- Items invoke the same action map as the D-Bus path

Visual style follows `Theme` (not the DE’s GTK theme). That is acceptable:
the fallback exists so the product works without Vala Panel, not so it clones
a GNOME/KDE menubar pixel-for-pixel.

**Probe order (once at startup, re-check on bus name owner change if cheap):**

```text
if env LAVA_MENU == vulkan → VulkanMenuHost
else if dbusmenu + registrar available → DBusMenuHost
else → VulkanMenuHost
```

Switching live from DBusMenu to Vulkan when the panel dies mid-session is
nice-to-have; v1 can pick once at open.

#### Wayland

AppMenu Registrar historically keys menus by **X11 window id**. On pure
Wayland there is no portable equivalent for non-GTK toolkits. v1 policy:

- Prefer DBusMenu only when an X11 xid is available (X11 or XWayland if the
  handle is still meaningful for the DE — verify per target DE).
- Otherwise use **VulkanMenuHost**.

Document this; do not block the feature on Wayland global-menu archaeology.

## Vulkan menu host (Linux fallback) — layout integration

```text
┌──────────────────────────────────────────┐
│  File   Edit   View          (menuH)     │  ← MenuBar strip (Yoga or fixed)
├──────────────────────────────────────────┤
│                                          │
│           app root (bodyH)               │
│                                          │
│     ┌─────────────┐                      │
│     │ Open…       │  ← Overlay when open │
│     │ Save        │
│     │ ─────────   │
│     │ Quit        │
│     └─────────────┘
└──────────────────────────────────────────┘
```

- `LavaApp` already subtracts `menuH` from content height and from pointer
  coordinates. Vulkan host sets `menuH` to the strip height; DBusMenu /
  Cocoa hosts leave it `0`.
- Open dropdowns use existing overlay rules (see `Overlay.swift`): emit after
  the tree, escape scissor, take input first, dismiss outside.
- Keyboard: Left/Right move among top-level menus when open; Up/Down among
  items; Enter activates; Escape closes. Shortcuts from `KeyShortcut` are
  matched in `onRawKey` (also useful on platforms where the OS does not
  deliver every accelerator into the app).

Implementation options for the strip itself:

1. **Framework-owned chrome** — `MenuHost` installs a small retained tree
   above the user’s root (not part of `makeRoot()`). Cleaner separation.
2. **Injected into the host root** — `VStack { MenuBarView(model); userRoot }`.
   Simpler plumbing, easier for users to accidentally style-conflict.

Prefer (1): the bar is platform chrome that happens to be drawn by us when
the OS will not.

## Event and invalidation flow

```text
User picks item
    → OS / Overlay
    → MenuID
    → main queue (same as agent wake / MainQueue)
    → action map[id]?()
    → @State / observables dirty
    → next frame: body → maybe new MenuModel → host.apply if changed
```

Do not run heavy work inside Win32 WndProc or D-Bus signal handlers; enqueue
only.

## Shortcuts

`KeyShortcut` is shared:

- Seed native key equivalents (macOS / Win32 accelerators / DBusMenu shortcut
  properties when the panel supports them).
- Always also match in-app on key events so Linux Vulkan fallback and partial
  DBusMenu implementations still honor Ctrl/Cmd+S etc.

Primary modifier: Command on macOS, Control on Linux/Windows (or a single
`.primary` that resolves per OS).

## File / module layout

```text
Sources/LavaMenu/          // pure IR + DSL (no C++ / GPU)
  Menu.swift               // MenuBar, Menu, MenuItem, MenuModel, MenuController

Sources/LavaUI/
  MenuHost.swift           // backend selection; wraps MenuController + apply
  MenuBarView.swift        // Vulkan strip + overlay menus (Linux fallback)

canvas/src/menu/           // or adjacent to window_platform
  menu_host.hpp/cpp        // C ABI: apply model blob / clear / poll activations
  menu_cocoa.mm
  menu_win32.cpp
  menu_linux_dbus.cpp      // optional at link time
```

`LavaMenu` owns IR and policy; later C++ owns OS objects and native handles
(same split as clipboard and tool-window hints).

## Dependencies

| Platform | Build | Runtime |
|---|---|---|
| macOS | AppKit (system) | — |
| Windows | user32 | — |
| Linux DBusMenu | optional `libdbusmenu-glib`, GLib | Registrar + panel applet |
| Linux Vulkan fallback | none beyond existing LavaUI | — |

Missing optional Linux libs → compile with DBus path disabled → always Vulkan
fallback. No hard GTK dependency.

## Testing

- **IR / diff:** pure Swift tests — build model from DSL, equate, enable flags.
- **Vulkan host:** existing headless/agent layout tools can see the strip and
  open overlay (labels, hit targets) like any other view.
- **DBusMenu:** manual on a machine with vala-panel-appmenu; optional CI job
  later with a mock registrar.
- **Win32 / Cocoa:** when those platforms are first-class build targets.

## Phased delivery

1. **`MenuModel` + DSL + action table** — no platform, unit-tested.
   **Done** (`Sources/LavaMenu/`, `Tests/LavaMenuTests/`): pure target like
   `LavaText` so headless tests need no C++/Vulkan. `LavaUI` depends on and
   `@_exported import`s `LavaMenu`. Types: `MenuBar` / `Menu` / `MenuItem` /
   `MenuSeparator`, `MenuModel` IR, `MenuActionTable`, `MenuController`,
   `KeyShortcut`.
2. **VulkanMenuHost** — Linux always works; proves `menuH`, overlay menus,
   shortcuts, integration with `LavaApp`.
3. **Linux DBusMenuHost** — probe Registrar; export tree; fall back to (2).
4. **Win32** when Windows is a real target.
5. **Cocoa** when macOS is a real target.
6. **Context menus** sharing IR (Overlay and/or `TrackPopupMenu` /
   `popUpContextMenu`).

Shipping (2) before (3) matches the product rule: **a menu bar always
exists**; global panel integration is an enhancement when the DE provides it.

## Decisions

| Topic | Decision |
|---|---|
| Declaration site | App-level `LavaApp.run(..., menu:)` for the bar |
| Linux without Vala Panel | Draw menubar + menus with Vulkan / LavaUI |
| Linux with Vala Panel (or compatible) | DBusMenu + Registrar; no in-window bar |
| GTK widgets in-process | No |
| Wayland global menu | Not required for v1; use Vulkan fallback |
| Overlay vs native | Overlay only for fallback and in-canvas UI; command menus prefer OS |
| `menuH` | Non-zero only for Win32 native bar and Linux Vulkan fallback |

## Open questions

- Exact probe for “Registrar available” (name owner vs successful
  `RegisterWindow`).
- Whether nested submenus in the Vulkan fallback need a second overlay level
  or a single sliding panel.
- Icon support on items (defer; labels first).
- Whether `LAVA_MENU=dbus|vulkan|auto` is worth documenting for users or only
  for developers.

## Related

- `Sources/LavaUI/FileDialog.swift` — native dialog pattern
- `Sources/LavaUI/Overlay.swift` — in-app popup rules used by Vulkan fallback
- `Sources/LavaUI/LavaApp.swift` — `menuH` content offset
- `canvas/src/window/window_platform.cpp` — native window handles
- Vala Panel Application Menu: https://github.com/rilian-la-te/vala-panel-appmenu
- DBusMenu / AppMenu Registrar (Unity protocol used by the panel)
