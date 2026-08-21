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
            // First top-level menu = application menu (Chrome: "Google Chrome").
            // Global panels put it beside the window icon; omit it and that
            // slot looks empty/invisible.
            Menu("MyApp") {
                MenuItem("New", shortcut: KeyShortcut(KeyCode.n, .primary)) { newDoc() }
                MenuSeparator()
                MenuItem("Quit", shortcut: KeyShortcut(KeyCode.q, .primary)) {
                    editor.requestClose()
                }
            }
            Menu("File") {
                MenuItem("Open…", shortcut: KeyShortcut(KeyCode.o, .primary)) { open() }
                MenuItem("Save", shortcut: KeyShortcut(KeyCode.s, .primary), isEnabled: canSave) {
                    save()
                }
            }
            Menu("Edit") {
                MenuItem("Copy", shortcut: KeyShortcut(KeyCode.c, .primary)) { copy() }
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

### Connecting menu actions to view state

The menubar is built outside the view tree (`LavaApp.run(menu:)`), so it
cannot close over a view’s `@State` — those wrappers are value copies that
die with the builder call. Share an **`@Observable` class** instead:

```swift
@Observable
final class MySession {
    var document = ""
    var showSettings = false
    func openFile() { … }
}

let session = MySession()
LavaApp.run(editor: editor, menu: {
    MenuBar {
        Menu("File") {
            MenuItem("Open…") { session.openFile() }
            MenuItem("Settings…") { session.showSettings = true }
        }
    }
}) {
    MyRoot(session: session)  // body reads session.* → Observation invalidates
}
```

TraceLoom uses this as `TraceLoomSession`.

#### Why the model write reaches the screen

Observation only notices a write if some `body` **read** that property while
`withObservationTracking` was recording. Most controls do read: `Expand`
evaluates `isExpanded.wrappedValue` in its own body, so a menu toggling
`session.showLog` invalidates correctly.

`overlay(isPresented:)` deliberately does not — it holds a live closure and
reads it at emit time, so presentation costs a redraw instead of a body pass.
That means an `@Observable` write which *only* an overlay reads registers no
dependency and invalidates nothing.

Handlers therefore request a redraw themselves: `LavaApp` marks one after a
click action, and `MenuHost` after a menu activation. `.redraw` is the floor,
not `.body` — anything that genuinely changed the tree has already raised
`.body` through observation. Menu activations especially need this, because
panel clicks arrive from `poll()` outside any input event: on an idle window
nothing else would ask for a frame, and the action would sit unpainted until
the user happened to move the mouse.

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

AppMenu Registrar historically keys menus by **X11 window id**. On this
compositor Lava uses three paths:

1. **Lava clients** — the registrar's key is a `u` on the wire; clients register
   under their **surface id** (the same id `SubscribeActiveWindow` reports).
2. **Foreign Wayland clients (Qt6 / Chrome / KDE)** — the compositor advertises
   **`org_kde_kwin_appmenu_manager`**. The client exports dbusmenu as usual and
   calls `set_address(service, path)` on the surface. Focus carries those
   strings to the panel, which opens `DbusmenuClient` on them directly. This is
   the same protocol Dolphin uses on Plasma.
3. **X11 / Xwayland clients (Qt5 xcb, GTK with appmenu-gtk-module)** — the app
   still calls `RegisterWindow(xid, path)` with its X11 window id. Focus
   reports that XID as `ActiveWindow.surfaceId`, so the panel's registrar
   lookup matches.
4. **Qt5 on Wayland** — `libQt5WaylandClient` has no `org_kde_kwin_appmenu`
   (that is Qt6) and `RegisterWindow` uses `QWindow.winId()`, which is often
   just `1`. Focus also carries the client's Unix `pid`; the panel matches the
   registrar entry by that pid when the window id misses. `LAVA_MENU_DEBUG=1`
   logs the registrar calls, the lookup (`kde-appmenu` / `registrar-id` /
   `registrar-pid` / `none`), and imported top-level titles.

Chromium (VSCode, Teams, and Chrome's own bar) exports File/Edit with
`children-display=submenu` and no children. `AboutToShow` fills them and
returns `needUpdate=false`, so libdbusmenu never refetches. Opening a title
therefore AboutToShows, GetLayouts the object itself, and rebuilds the
dropdown before the first frame that shows it. Nested empty submenus under
that title get the same treatment so "Open Recent" is not a dead header.

**Under the lava compositor that is now solved**, and the answer was smaller
than the archaeology suggested: the registrar's key is a `u` on the wire and
nothing on the panel side looks it up in an X server. So a Lava client registers
under its **surface id** — the number the compositor already uses to name its
window, and the same number it reports as focused.

```text
    app (LavaUI client)                     LavaTaskbar
    ────────────────────                    ───────────
    DbusmenuServer at                       owns the registrar name
    /com/canonical/menu/<surfaceId>  ──┐    (canonical, else org.lavaui.…)
                                       │
              RegisterWindow(surfaceId, path)
                                       │
                                       ▼
                              DbusmenuClient reads the layout
                                       ▲
    compositor  ──SubscribeActiveWindow──┘   which window's menu to show
```

Three pieces make it work, and each is where it is for a reason:

- **`MenuImportHost`** (`canvas/src/menu/menu_import.*`) is the panel's half:
  it serves the registrar and imports layouts. Separate class from
  `AppMenuHost` — publishing a menu and reading other applications' menus are
  different jobs and no process should accidentally do both.
- **`SubscribeActiveWindow`** on the control plane says *whose* menu. Focus
  belongs to the compositor; a panel guessing would show the wrong app's File
  menu. It carries the client's pid so Qt5 Wayland menus can be found at all.
- **`SetPanelThickness`** lets the 32pt strip grow while a dropdown is open
  and shrink afterwards, reserving the strip either way, so windows do not
  move when a menu opens.

Bus name: the panel takes `com.canonical.AppMenu.Registrar` when it is free —
then Qt and GTK applications export to it with nothing changed on their side —
and `org.lavaui.AppMenu.Registrar` when a host desktop (KDE, say) already owns
the canonical one. Applications prefer the lava name where both exist, since
both means "a lava panel inside somebody else's session".

Applications also *re-register* when a registrar appears on the bus
(`g_bus_watch_name`), so restarting the panel does not empty it. What still
does not recover is an app that started when there was no registrar at all: it
picked the in-window bar at startup and keeps it, because the backend is
chosen once. Start the panel before the apps — which a session does anyway.

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
  Menu.swift

Sources/LavaUI/
  MenuHost.swift           // vulkan | dbusMenu selection, export, poll
  MenuBarView.swift        // Vulkan strip + overlays
  LavaApp.swift            // run(..., menu: { MenuBar { … } })

canvas/src/menu/
  app_menu.hpp/cpp         // DBusMenu server + AppMenu Registrar (optional)
```

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
2. **VulkanMenuHost** — Linux always works; proves overlay menus, shortcuts,
   integration with `LavaApp`.
   **Done** (`MenuHost`, `MenuBarView` / `MenuChromeRoot`, `LavaApp.run(menu:)`):
   in-window strip + `Overlay` dropdowns; shortcuts via `MenuHost.activate(matchingKey:)`.
   The strip is **inside** the view tree (not a separate `menuH` client offset).
3. **Linux DBusMenuHost** — probe Registrar; export tree; fall back to (2).
   **Done** (`canvas/src/menu/app_menu.*`, `MenuHost` backend selection):
   - Optional build dep `dbusmenu-glib-0.4` + `gio-2.0` (`CANVAS_HAVE_DBUSMENU`)
   - `com.canonical.AppMenu.Registrar` + X11 window id
   - `LAVA_MENU=vulkan|dbus|auto` override
   - GLib pump before/after `pumpEvents`; idle wait capped (~20ms) while DBus
     is active so panel GetLayout/AboutToShow always get replies (unbounded
     `glfwWaitEvents` freezes XFCE/the panel). Activations also
     `glfwPostEmptyEvent`.
4. **Win32** when Windows is a real target.
5. **Cocoa** when macOS is a real target.
6. **Context menus** sharing IR (Overlay and/or `TrackPopupMenu` /
   `popUpContextMenu`).

Default on Linux: try global menu, else Vulkan strip — **a menu bar always
exists**.

## Decisions

| Topic | Decision |
|---|---|
| Declaration site | App-level `LavaApp.run(..., menu:)` for the bar |
| Linux without Vala Panel | Draw menubar + menus with Vulkan / LavaUI |
| Linux with Vala Panel (or compatible) | DBusMenu + Registrar; no in-window bar |
| GTK widgets in-process | No |
| Wayland global menu | Not required for v1; use Vulkan fallback |
| Overlay vs native | Overlay only for fallback and in-canvas UI; command menus prefer OS |
| `menuH` | Non-zero for Win32 native bar only; Vulkan fallback embeds the strip in the view tree (`menuH` stays 0) |

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
