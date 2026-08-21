# AGENTS.md — LavaUI monorepo

Guide for coding agents working in this repository. Prefer this over guessing
layout from filenames alone. Human-oriented product docs stay in `README.md`
and `docs/`.

## What this is

**LavaUI** is a declarative UI framework in Swift that draws with **Vulkan**.
Views look SwiftUI-shaped (`body`, `@State`, stacks, modifiers) but the stack
under them is owned here: Yoga layout, FreeType/HarfBuzz text, an
immediate-mode `DrawList`, and a C++ engine (`canvas/`) that rasterizes and
presents.

There is also a **wlroots compositor** (`compositor/`) that can host LavaUI
apps as GPU-less clients: the app lays out and emits draw lists into a shared
memory **draw arena**; the compositor owns Vulkan, fonts atlases, and windows.
Control-plane RPC (fonts, images, surfaces, present, input) goes over **NPRPC**
shared memory (`idl/lava.npidl`). Pixels do **not** go through RPC.

Linux + Swift 6 + C++ interop only for anything that links the engine.

## Architecture (two run modes)

```
┌──────────────────────────── windowed ─────────────────────────────┐
│  LavaUI app  →  CxxCanvas (local Vulkan)  →  GLFW window          │
└───────────────────────────────────────────────────────────────────┘

┌────────────────────── LAVA_CLIENT=1 (client) ─────────────────────┐
│  LavaUI app (no GPU)                                              │
│    · body / layout / emit → DrawArena (SHM)                       │
│    · RegisterFont / RegisterImage / CreateSurface / Present       │
│         ↕ NPRPC shm (~µs RTT)                                     │
│  compositor (wlroots + canvas)  →  scene / decorations / input    │
└───────────────────────────────────────────────────────────────────┘
```

| Concern | Where it lives |
|---|---|
| View DSL, state, invalidation | `Sources/LavaUI` |
| Text editing (no GPU) | `Sources/LavaText` |
| Menu IR (no GPU) | `Sources/LavaMenu` |
| Vulkan, fonts, images, arenas | `canvas/` → product `CxxCanvas` |
| Compositor + control plane servant | `compositor/` |
| RPC IDL (one source of truth) | `idl/lava.npidl` |
| Generated Swift stubs | `Sources/LavaIDL` (checked in) |
| Generated C++ stubs | `compositor/src/gen` (checked in) |
| Client connect / Present / input | `Sources/LavaClient` |

### Frame pipeline (always the same mentally)

1. **body** — rebuild retained tree when state requires it
2. **layout** — Yoga (`CYoga`)
3. **emit** — walk tree → `DrawList`
4. **present** — engine presents, or client publishes arena + `Present` RPC

Invalidation levels: `.none` / `.redraw` / `.layout` / `.body`. A pure redraw
skips body and layout. `LAVAUI_DEBUG=1` prints per-frame stage timings.

### The shared renderer (scene tree) — read this before touching scroll or hover

The compositor's canvas is not a dumb blitter. A draw list carries **scene
nodes** (`BeginNode` / `EndNode` in `draw_command.hpp`), which are named
subtrees the renderer owns *between* client frames:

| Flag | Meaning |
|---|---|
| `kSceneNodeClip` | scissor children to the node rect |
| `kSceneNodeScrollY` / `ScrollX` | renderer may translate this subtree |
| `kSceneNodeHitTest` | renderer resolves hover/press here |
| `kSceneNodeAbsoluteCoordinates` | commands inside are window-space already |
| `kSceneNodeWheel` | the widget handles the wheel itself; do not scroll its container |

Consequences that surprise people:

- **Scrolling is renderer-side.** The compositor eases `scrollX/scrollY` and
  reports the result back as a `.nodeScroll` input event; the client *adopts*
  the offset for hit-testing and lazy mounting (`ScrollNode.adoptRendererOffset`)
  rather than driving it. A stopped client still scrolls — as far as the
  overscan it last emitted (`ScrollView.paintedSpan`).
- **Hover tints are renderer-side** too, which is why a hover costs no round
  trip and why `.nodeHover` must not force a client repaint.
- One wheel detent is `kPixelsPerNotch` (72) in `render_window.cpp`. Both input
  paths normalise a detent to one notch first — GLFW's Wayland backend scales
  the protocol's 15 units by 1/10, the compositor divides by 15 or prefers
  `delta_discrete / 120`.
- A wheel has only a Y axis, so over a container that scrolls **only** in X the
  renderer maps the vertical wheel onto X (`RenderWindow::scrollScene`).

### Renderer facts worth knowing before debugging pixels

- **Colours are sRGB end to end** (picker / hex / `Color(r:)`). Nothing in
  the 2D pipeline applies a transfer function: every attachment is `*_UNORM`,
  vertex colours pass through, and `Color(r: 0.5)` is `#808080` on screen.
  Do not pre-linearise in `Color.rgba8` — the colour would arrive dark.
- **Blending happens in sRGB, so alpha means what CSS means by it.** What
  shows through at alpha `a` is `1 - a` of the background, same as a browser.
  This changed on 2026-08-19; before that every attachment was `*_SRGB` and
  blending was linear, which made the useful range of a window wash 0.98–1.0.
  **Do not retune an alpha by arithmetic.** `1 - a` is what the *blend unit*
  does, not what reaches the eye: a frosted window has a second tint under the
  wash and the blur composite has an alpha of its own, and the old linear leak
  scaled with the brightness behind each pixel rather than being a flat
  percentage — so no constant reproduces an old look. `TerminalPalette
  .windowAlpha` was moved 0.99 → 0.93 on that reasoning and came out far too
  transparent; it is back at 0.99. Tune by eye against a real wallpaper.
  The reason for the change is the buffer handover, not taste: Wayland's
  premultiplied contract is on the stored bytes (`rgb <= a`), and
  premultiplying in linear light then encoding stores `encode(L*a)`, which is
  strictly greater than `encode(L)*a`. wlroots added the excess over the
  desktop — a white rim on every antialiased edge that crossed onto the
  transparent part of a surface. **Read `docs/colour-and-blending.md` before
  picking any alpha value** — it has the numbers, what the change cost (blur
  and mipmaps now average encoded values) and what it did not (`Scene3D`
  lighting converts explicitly on the CPU and is unaffected).
- **One descriptor set per texture *change*.** Batches are emitted in tree
  order with no sorting, so a grid pairing an atlased icon with a glyph label
  costs two per cell. The pool grows in chunks of `kDescriptorSetsPerChunk`
  (64) up to `kMaxDescriptorChunks`; past that it warns and draws the *wrong*
  texture rather than nothing. Keep images atlasable: `ImageAtlas` refuses
  anything wider than one 256px cell, so pass `decodePixels`/`maxPixelSize`
  whenever the box is a percentage rather than a point size.
- **Backdrop blur captures this surface's own framebuffer**
  (`RenderDevice::resolveImage`), never the desktop. A client cannot frost what
  is behind its window; that would need a compositor-side effect.
- Blur scopes do **not** nest — the outermost wins (`DrawList.withBlurScope`).

### Layout traps (LavaUI)

- **A column stack that states its own width gets `theme.panel` for free.**
  `StackNode.apply` does this so a sidebar looks like a sidebar
  (`case (.column, .point), (.column, .percent)`). Write
  `VStack(width: .pct(100))` in a full-width container and you paint the whole
  window `panel`, burying everything under it. Let columns stretch instead, or
  use `.frame(width:)`, which goes through the modifier and does not trigger it.
- A modifier that paints lands on the content's own node when that node can
  show it (`LeafNode` / `StackNode` / `StyleBoxNode`) and otherwise wraps in a
  `StyleBoxNode`. Order still matters: `.background()` *after* a modifier that
  wraps applies to the wrapper.

### Client mode rules of thumb

- `LAVA_CLIENT=1` → `LavaClient.open` / `LavaClient.run` (not a separate app).
- Fonts/images are registered with the **compositor**; ids stamped into draw
  commands must be ones the compositor understands. Fonts are
  **content-addressed** (`FontKey`: hash of bytes, face index, 26.6 size, …).
- Draw lists: shared **DrawArena**. Control plane: small RPCs only.
- **Global menu**: `LavaTaskbar` owns the AppMenu registrar and draws the
  focused window's menu (`canvas/src/menu/menu_import.*` imports it,
  `SubscribeActiveWindow` says whose, `SetPanelThickness` makes room for the
  dropdown). A client registers under its **surface id**, not an X11 id — so
  client-mode apps no longer fall back to an in-window menubar. See
  `docs/native-menus.md`.
- Window frame is the **client's** choice at `CreateSurface`:
  `LavaClient.open(frame: .client)` gets no compositor title bar, and the app
  places `WindowControls()` / `.windowDrag()` itself (`Sources/LavaUI/
  WindowControls.swift`). `BeginMove` / `ToggleMaximize` / `Minimize` are how
  it asks; close is just the app ending.
- `Present` and `ScrollUnclaimed` are IDL **`[unreliable]`** — fire-and-forget,
  no reply. Never wait for a response on those (Swift uses
  `sendUnreliable`).
- NPRPC object timeout defaults to **1s**. Long work (surface create, image
  decode, capture) must raise the proxy timeout, not only a local semaphore.
- Servants hop to the **Wayland event loop** before touching wlroots/Vulkan.
- **`LavaClient.open` returns before the surface exists.** It hands back an
  `Editor`; `createSurface` happens on the way into `run`, so `surfaceID` is
  still 0 during app setup. Anything that needs an id (`SetMinSize`,
  `SetInputRegion`) must either be called later or, better, store the request
  and flush it when the id arrives — see `LavaClient.setMinimumSize`. A guard
  that silently returns here looks exactly like a broken compositor.
- Adding a call: edit `idl/lava.npidl`, run `scripts/gen_stubs.sh`, implement
  the servant in `compositor/src/control_plane.cpp`, add the virtual to
  `CompositorHost` (`control_plane.hpp`) and the body on `SurfaceRegistry`.
  Method indices are positional — regenerating both stubs together is what
  keeps client and server agreeing.

### Compositor policy decisions already made

- **Who draws the title bar.** A client that explicitly asks xdg-decoration for
  client side gets it and no frame (Chromium, Electron: their header *is* their
  tab strip and overriding it just yields two rows of buttons). Server side or
  no preference gets the compositor's frame; clients that never bind the
  protocol (GTK) get none. X11's equivalent is the Motif hint.
- **Input regions are honoured by the scene, not just by us.**
  `point_accepts_input` on each content buffer means a 600px-tall panel that
  only claims a 32px strip stops occluding the windows underneath. Shadows
  accept nothing. Both hit paths (`hitTestPass` and `wlr_scene_node_at`) must
  agree or clicks land where motion did not.
- **Popups** (`xdg_popup`) need three things: a scene subtree under the
  parent's, a configure on `initial_commit`, and unconstraining against the
  work area **in the root toplevel's coordinates** — not the immediate
  parent's, or submenus drift off-screen a level at a time.
- **Clicking the desktop clears focus** (`Server::blurAll`), which is what
  makes the panel fall back to its own menu. Tested on the surface under the
  pointer, not on the toplevel: a popup resolves to no toplevel.

Sibling checkout often expected:

```text
…/projects/HelloWorld/     # this repo
…/projects/nprpc/          # NPRPC (optional path dep via Package.swift)
```

`scripts/fetch-nprpc.sh` will also clone (or symlink) it at
`third-party/nprpc`. Meson and Package.swift look in both places.
Without nprpc, the package still builds; control-plane products
(`LavaClient`, full client mode) are gated on detecting `nprpc_swift`.

## Repo map

```text
scripts/           bootstrap, install-deps, nprpc fetch/build, Docker, VM
docker/            Debian 13 + Arch images that run meson test + swift test
vm/                cloud-init for the QEMU install-test guest
packaging/deps/    Debian/Arch package lists (source of truth for install-deps)
Sources/
  LavaUI/          Framework (views, layout host, draw list, fonts, input)
  LavaText/        Editing logic — no C++, no Vulkan (unit-tested hard)
  LavaMenu/        Menu DSL / IR — no drawing
  LavaClient/      Compositor client library
  LavaHost/        Runtime window/compositor selection for app entry points
  LavaIDL/         Generated NPRPC Swift stubs (do not hand-edit long-term)
  LavaBench/       Perf suite vs committed baseline
  LavaSurface/     Client: wallpaper / desktop surface
  LavaTaskbar/     Client: panel / taskbar (global menu)
  LavaDock/        Client: dock — open windows on this workspace
  LavaSwitcher/    Client: 3D Ctrl+Tab / Mod+Tab app switcher
  LavaDebug/       Client: where the compositor's VRAM went (`--once` for text)
  HelloWorld/      Demo playground + FBD bits
  LavaTerm*/       Terminal emulator (core headless + app)
  Spotify*/        LavaSpotify (core headless + app)
  TraceLoom*/      Log / trace viewer + Ollama assistant
                   (`TraceLoom a.log b.log` opens a tab each;
                    `TraceLoom x.traceloom` reopens a saved workspace)
  Weather*/        LavaWeather (core headless + app; Open-Meteo, no API key)
  FBDModel/        Function-block diagram model
canvas/            C++ Vulkan engine + Yoga (SwiftPM C++ targets)
compositor/        wlroots compositor + canvas surfaces + control plane
idl/lava.npidl     Control-plane IDL
docs/              Design notes, API, performance, gaps
tools/             Agent CLI / MCP over LAVA_AGENT_PORT
Tests/             Headless Swift tests (no GPU required for most)
```

**Dependency hygiene (enforced by Package.swift):**

- `LavaText` / `LavaMenu` / `*Core` targets have **no** engine dependency.
- `LavaUI` must stay free of NPRPC **unsafeFlags** so it can be a GitHub
  package. Control plane sits in `LavaClient` / `LavaIDL` above the framework.

## Build and test

```bash
# Clean Debian/Arch machine (packages, wlroots 0.19, nprpc, both builds)
./scripts/bootstrap.sh --yes          # see docs/install.md
./scripts/check-env.sh

# App + engine (SwiftPM builds C++ canvas)
swift build
swift test
swift run HelloWorld

# Perf (release; fails on baseline regression)
swift build -c release && ./.build/release/LavaBench

# Client of compositor (needs nprpc + running compositor)
# compositor: meson build under build/ (see compositor/README.md)
LAVA_CLIENT=1 swift run LavaSurface
LAVA_CLIENT=1 swift run HelloWorld

# Regenerate RPC stubs after editing idl/lava.npidl
NPIDL=…/nprpc/.build_relwith_debinfo/npidl/npidl scripts/gen_stubs.sh
```

System needs: Vulkan ICD, GLFW, FreeType, HarfBuzz; for global menus
GLib + libdbusmenu-glib. SPIR-V is checked in; after GLSL edits run
`canvas/scripts/compile_shaders.sh`.

Compositor is **Meson** (`meson setup build && ninja -C build`), separate from
SwiftPM. Scripts under `compositor/scripts/` (`dev-run`, `start-lava-compositor`,
optional QEMU VM).

`meson test -C build` runs the C++ tests under `canvas/tests/`. They cover the
parts that can be tested without a GPU or a screen — today the draw arena's
handoff and growth protocol, whose consumer once unmapped a generation a frame
was still being drawn out of. A test there is compiled from the sources it
exercises rather than linked against `libcanvas`, so it stays runnable
anywhere.

### Useful environment

| Variable | Effect |
|---|---|
| `LAVA_CLIENT=1` | App as compositor client |
| `LAVA_FRAME=server` | HelloWorld: compositor title bar instead of its own chrome |
| `LAVA_AGENT_PORT=9876` | Local agent TCP server (layout / input / screenshots) |
| `LAVAUI_DEBUG=1` | Per-frame body/layout/emit/present timings |
| `LAVAUI_PROFILE=1` | Per-widget paint profiling via agent `profile` |
| `LAVA_EDITOR_PROBE=1` | Editor hot paths (hit test, caret, selection, emit) with the buffer offset each was working at — see `EditorProbe` |
| `LAVA_FRAME_PROBE=1` | Compositor: per-surface frame cost, gaps and stalls |
| `LAVA_SCANOUT_PROBE=1` | Compositor: per output frame, whether a client covers it and whether that client's buffer is fenced — the input to the direct-scanout decision |
| `LAVA_VRAM_STATS=1` | Compositor: GPU memory report to stderr, every 10s (`=N` for N seconds, `=verbose` for every allocation). Rides the output frame, so an idle desktop stops reporting — `kill -USR2` dumps one on demand |
| `LAVA_MSAA=N` | Any canvas process: cap multisampling at N (1/2/4/8). Overrides `[render] msaa`; the way to A/B a session without a rebuild |
| `LAVA_SHARED_DEPTH=0` | Compositor: one depth attachment per window again, for comparing against the shared one |
| `LAVA_EXPORT_BLIT=1` | Compositor: blit each frame into the exported dma-buf instead of resolving into it, as it did before — the A/B for that change, and the escape hatch where a driver dislikes it |
| `LAVA_BLUR_SHIFT=N` | Any canvas process: octaves below the window the blur pyramid starts at (0/1/2). 0 captures at window size, as it did before |
| `LAVA_NO_SHELL=1` | Compositor: do not start panel/dock/wallpaper |
| `LAVA_NO_AUTOSTART=1` | Compositor: do not run the user's autostart script |
| `LAVA_AUTOSTART` | Path to that script, overriding `~/.config/lava/autostart` |
| `LAVA_COMPOSITOR_IOR` | Client: the compositor reference to use, overriding the one named by `WAYLAND_DISPLAY` |
| `WLR_BACKENDS=headless` `WLR_RENDERER=vulkan` | Compositor with no screen (see below) |
| `WLR_LOG=debug` | wlroots + compositor debug logging (popups, scene) |
| `LAVA_BOOT_TRACE=1` | Where the time before a client's first frame went |
| `CANVAS_VK_VALIDATION=1` | Vulkan validation layers |
| `NPRPC_SWIFT_PATH` | Override path to `nprpc_swift` package |
| `NPRPC_ROOT` / `NPRPC_BUILD_DIR` | In-tree nprpc link for Swift bridge |

Runtime agent protocol (MCP/CLI, stable `sid`s, hit-testing): **`docs/agent.md`**.

## Verifying a change without a screen

Most of this repo can be exercised headlessly, and the recipe is worth copying
rather than rediscovering.

```bash
# A compositor of your own. A separate XDG_RUNTIME_DIR is still the tidiest
# way — nothing of the live session is then reachable by accident at all.
export RT=/tmp/lvt          # keep it SHORT: the wayland socket path has a
mkdir -p $RT && chmod 700 $RT   # 108-byte limit and long paths fail to bind
XDG_RUNTIME_DIR=$RT WLR_BACKENDS=headless WLR_RENDERER=vulkan \
  LAVA_NO_SHELL=1 ./build/compositor/compositor &

# A client of it, with the agent server on for scripted input + screenshots
XDG_RUNTIME_DIR=$RT WAYLAND_DISPLAY=wayland-0 LAVA_CLIENT=1 \
  LAVA_AGENT_PORT=9876 ./.build/debug/LavaTerm &
```

### Two compositors at once

Sharing a runtime directory with a running session is supported, which is what
makes a **nested** compositor — one started from a terminal inside the live
one, on the `wayland` backend — a usable way to develop this:

```bash
WLR_BACKENDS=wayland WLR_RENDERER=vulkan ./build/compositor/compositor &
```

Each compositor publishes its control plane under the name of its own Wayland
socket, `$XDG_RUNTIME_DIR/lava-compositor-<session>.ior`, and every client
resolves that name from the `WAYLAND_DISPLAY` it inherited — so a client
started from a terminal inside the nested session reaches the nested
compositor, and one started outside reaches the outer one, with nothing to
configure either way. The window an app opens follows from where it was
launched, which is the same rule Wayland clients already obey.

Overriding by hand, in order of precedence:

| Variable | Effect |
|---|---|
| `LAVA_COMPOSITOR_IOR` | Full path to a reference file — reach a compositor whose environment you did not inherit |
| `WAYLAND_DISPLAY` | Names the session, and therefore the reference file |
| neither | The one session running, if exactly one; otherwise the client says which are and stops |

Draw arenas carry the session in their name too (`lava-arena-<app>-<session>-<pid>`),
which is a labelling convenience rather than routing: `/dev/shm` is one
namespace for the whole machine, but an arena id travels over the client's own
connection to the compositor that then opens it, so no arena is ever ambiguous
about who it is for.

`SIGTERM` and `SIGINT` are an orderly shutdown — the reference is unlinked, the
shell components are stopped, clients see a display that closed. Killing a
nested compositor with `kill` therefore leaves nothing behind; `kill -9` leaves
a stale `.ior`, which the next compositor on that socket name overwrites.

Then drive it over the agent port (JSON lines, one request per connection):
`settle`, `screenshot`, `find`, `hit_test`, `click`, `move`, `scroll`,
`type_text`, `key`, `layout_tree`, `fb_size`, `profile`. Screenshots come back
as base64 PNG, which is the fastest way to check a layout claim.

**Before killing anything**, confirm it is yours:

```bash
grep -qa "$RT" /proc/$PID/environ && echo mine || echo "leave alone"
```

The user's session compositor and their browser look just like test processes
in `pgrep` output. `pkill -f` on a pattern that matches your own shell command
will also kill the shell.

### What headless cannot do

| Cannot | Why | Do instead |
|---|---|---|
| Move the real cursor / click the desktop, drag a window edge, right-click for a popup | headless wlroots has no input devices, and there is no virtual-pointer protocol | drive the app's own agent port — or, when the bug is in the compositor's own routing, a throwaway signal hook (below) |
| See overlay content from the agent | `find`/`layout_tree` walk the main tree; a presented overlay's subtree is detached | click by coordinate |
| Reach the compositor's scene scroll from a client's agent | agent input is injected into that client's engine | test scene-level behaviour in **windowed** mode, where the app owns the renderer |

### Driving compositor input with a throwaway signal hook

The agent port injects into a client's *own* engine, so it never crosses the
compositor. That is the right tool for a layout claim and the wrong one for
anything whose bug lives in the compositor's routing — a keybinding, an input
region, a `PointerLeave`, panel hover. Those need a real event through
`route_pointer` / `on_key`, and nothing in the tree can produce one.

What works is a hook compiled in for the length of one investigation and taken
back out before committing. `wl_event_loop_add_signal` delivers on the loop
thread, so the handler may call anything the compositor itself calls:

```cpp
// TEMPORARY PROBE — remove. Also add the signal to the mask in `main`,
// beside SIGHUP: wl_event_loop_add_signal reads a signalfd, and a signalfd
// only sees signals that are blocked.
wl_event_loop_add_signal(
    wl_display_get_event_loop(server.display), SIGUSR1,
    [](int, void *data) {
      auto *server = static_cast<Server *>(data);
      server->toggleShowDesktop();          // whatever the binding calls
      return 0;
    },
    &server);
```

For the pointer, warp and then re-run the routing the way real motion does —
this exercises input-region hit testing and the leave/enter edges, which is
where such bugs actually are. Signals carry no payload, so read the
coordinates from a file:

```cpp
wlr_cursor_warp_closest(server->cursor, nullptr, x, y);
server->update_pointer_focus(0);
```

Pair it with a `wlr_log` on whatever the change is about — `SetInputRegion`
arriving, a window minimizing — and the log becomes the assertion. A flicker
reads as a burst of alternating states from one warp; fixed, the same sweep
produces two transitions for the whole pass.

**Reproduce on the old build first.** `git show HEAD:compositor/src/main.cpp >
compositor/src/main.cpp`, apply the same hook, run the same script, and keep
the output. Without that half you have only shown that the new code does
something; you have not shown it was the bug the user reported. Keep the clean
copy somewhere the test cleanup will not delete — **not** under the
`XDG_RUNTIME_DIR` you are about to `rm -rf`.

### Seeing what the compositor drew

A client's agent screenshot shows that client's own surface. Everything the
*compositor* draws — shadows, frost, decorations, the wallpaper behind a
window, where a window actually landed — needs an output capture, and headless
has two. Both work with no pointer and no screen:

```bash
# 1. screencopy, if WAYLAND_DISPLAY points at the session under test
XDG_RUNTIME_DIR=$RT WAYLAND_DISPLAY=wayland-0 grim shot.png

# 2. the screenshot portal, over D-Bus, which needs neither
busctl --user call org.freedesktop.impl.portal.desktop.lava.test \
  /org/freedesktop/portal/desktop org.freedesktop.impl.portal.Screenshot \
  Screenshot 'ossa{sv}' /org/freedesktop/portal/desktop/request/probe "probe" "" 0
# → uri "file:///tmp/lava-shot-XXXXXX.png"
```

The portal's bus name is the `.test` one for a nested or headless compositor —
`nested` is true whenever `WAYLAND_DISPLAY` or `DISPLAY` was set when it
started — so a run inside your own session cannot answer for the desktop. That
is what makes calling it from an agent session safe.

`CaptureSurface` is the third and narrowest: one window, a foreign one from the
buffer it last committed. The 3D switcher's cards are that.

Print Screen puts the same output capture on the clipboard, and is the one that
needs a key.

Windowed mode under a nested compositor is fragile in one known way: if the
compositor clamps the window to a size the app did not request, the swapchain
can hit `VK_ERROR_OUT_OF_DATE_KHR` on acquire and the engine treats it as
fatal. Open at the size the output will actually grant to avoid it.

## Where the VRAM went

The compositor renders every LavaUI surface on the desktop on **one** Vulkan
device, so its VRAM is the desktop's, and no client can see any of it. Three
things answer for it, sharing one implementation:

| Route | What it is |
|---|---|
| `LAVA_VRAM_STATS` / `kill -USR2` | The report on the compositor's stderr |
| `GetGpuReport` (IDL) | The same report over the control plane |
| `swift run LavaDebug` | A window that polls it; `--once` prints text |

`canvas::GpuLedger` is the source: every VMA allocation in the engine goes
through `RenderDevice::createImage`/`createBuffer`, so tagging those two makes
the inventory *complete* rather than a sample, and the exported/imported
dma-bufs — the two things allocated outside VMA — register by hand.
Imported client buffers are counted separately and never added to this
process's own bytes.

Three totals that disagree, on purpose: what the driver attributes to the
process, what the allocator holds, and what the ledger can name an owner for.
The gaps are the information — allocator minus ledger is slack VMA is keeping,
driver minus allocator is the swapchain and the driver's own working set.

Two things to know before reading a report:

- **One window on screen is up to three canvas windows** — contents, title bar,
  backdrop frost — and they are wildly different sizes (frost is
  output-sized). The compositor names them in the report (`GpuWindow.title`);
  a bare canvas window id would send you looking for a client that owns none
  of it.
- **`DumpAtlasImages` writes the atlas pages as PNGs** rather than returning
  bytes, and `LavaDebug` then displays them by path. It idles the device to
  read each page back, so it is a button, never a timer.

### What the first report changed

Two things it found, both fixed, and the numbers are worth keeping because they
are what any similar decision should be argued with. Measured headless at
1920×1080 with one blurred terminal (its contents surface plus its frost
surface):

| Sample count | Accounted for | Per surface pair |
|---|---|---|
| 8 (was: device maximum) | 338 MiB | 310 MiB |
| **4 (`kDefaultSampleCap`)** | **211 MiB** | **183 MiB** |
| 2 | 151 MiB | 123 MiB |

MSAA buys very little here and it is worth knowing why before raising it again:
SDF shapes (rounded rectangles, the window buttons) are anti-aliased
analytically in `quad.frag`, text is coverage-blended from the glyph atlas, and
everything else in a UI is an axis-aligned rectangle. A full-screen capture at
8× against the same frame at 2× differs in **244 pixels of 2,073,600 (0.012%),
max channel delta 13** — all of it around two circles. Where it *would* show is
a real triangle edge: `Scene3D` in the switcher, `Mesh`/`Polyline` charts, FBD
diagrams. Set `[render] msaa` (or `LAVA_MSAA`) and look at one of those before
concluding 2 is free.

**Depth is one image for the whole device, not one per window.** It is
per-frame scratch — cleared at pass start, `DONT_CARE` at the end, and only
`Scene3D`'s pipeline even tests it — so 34 windows meant 34 copies of a
scratchpad, 28% of the session's VRAM. `RenderDevice::setSharedDepth` gives them
one, sized to the largest window (rounded up in steps of 256 so a drag does not
reallocate per pixel) and grown from `sharedDepthView`, which waits for frames
in flight and rebuilds every window's framebuffer before returning. Eight canvas
windows: 80 MiB → 12 MiB, and it stays 12 however many windows open.

**It is only legal because the compositor renders serially** — one
`renderFrame` at a time from its event loop. An app that repaints N windows on N
threads inside `beginFrameGroup` must not enable it, and does not: the switch is
set in `initExported`, the compositor path. Two windows each drawing
depth-tested 3D render *byte-identically* with it on and off, which is the test
that proves nothing leaks between them.

**The readback buffer is allocated on demand.** A full frame of host-visible
memory — 7.9 MiB at 1080p — was allocated and mapped for every window at
creation, and an exported window never touches it: its frame goes to a dma-buf. Now `ensureStagingBuffer` runs from the paths that actually read pixels
back (`captureFrame`, and the per-frame copy a window with no other destination
does), so a screenshot pays for it and nothing else does.

**The frame is resolved into the exported dma-buf, not blitted into it.** Every
exported window owned a single-sample resolve image the size of its frame, drew
into it, and then blitted the whole thing into the shared buffer — a second copy
of every surface on the desktop, and a full-screen blit per window per frame.
The dma-buf is now the render pass's resolve attachment, so the window owns no
resolve image at all and the frame ends with a queue-ownership release instead
of a copy. One window at 1280×720 (contents + shadow): 108.5 → 100.1 MiB, and
the `window resolve` category disappears from the report.

Two things had to line up, both negotiated rather than assumed, and either
answer works:

- **The format.** A framebuffer attachment must match the format its render
  pass was built with, and an image view may not swizzle one byte order into
  another — so `R8G8B8A8_SRGB`/`ABGR8888` can be rendered into and
  `B8G8R8A8_SRGB`/`ARGB8888` cannot. `DmabufImage::exportFormats()` names both,
  best first; the compositor answers with the modifiers it can import for each,
  and canvas picks a renderable pair if one exists.
- **The modifier.** Its tiling has to support `COLOR_ATTACHMENT` as well as
  being exportable. If nothing does, the buffer is still a fine blit
  destination and everything falls back to what it did before.

`DmabufImage::renderable()` is the one place that answer lives; `LAVA_EXPORT_BLIT=1`
forces the old path, which is how the two were compared. A full LavaUI frame —
3D shelf, image atlas, blurred backdrop, gradients, text — comes out **identical
in all 921,600 pixels** either way, and so does a growth to 2560×1440, which
exports a new buffer and rebuilds the framebuffers around it mid-session.

A window that is read back (`captureFrame`, so any screenshot) now acquires the
buffer from the consumer first: the only acquire whose *contents* matter, and
the reason `recordAcquireForRead` is not the discarding one the frame path uses.

**A frame that blurs does not go straight into the buffer, and that is not an
optimisation.** Every blur interrupts the main pass, and ending a pass resolves
it — so a blurred frame resolving into the shared image lands there *twice*:
once with everything drawn so far and nothing after it, and again at the end.
The consumer is told to wait for the submit, and nothing at all stops it
sampling between those two writes; what it draws then is the window with
everything below the blur missing. It looked like elements blinking in and out
while a list scrolled, and it is why exported buffers must be blit
*destinations* as well as attachments — `directToExport()` decides per frame,
from a pre-scan of the draw list, and a frame that blurs takes the old path
into this window's own resolve image and a copy at the end. Only blurred
windows carry a `window resolve` line in the report; a plain one still resolves
straight into its buffer.

That leaves the narrow race the old path always had — the consumer has a fence
saying *when the frame is written* and canvas has nothing saying *when the
consumer is done reading*, so a client that redraws while a composite is still
in flight can still overwrite the buffer under it. One buffer per window is
what makes that possible; the fix, if it ever matters, is a release timeline
back from the compositor, not a second buffer.

**A drop shadow is nine scene nodes onto one shared image.** Every focused
window used to get a canvas surface the size of itself plus the blur's reach —
a multisampled attachment, an exported dma-buf and a render on every move — and
a desktop of eleven windows had eleven pictures of the same thing at different
sizes. It *is* the same thing: the falloff of a rounded rectangle depends only
on the distance to it, so the picture is constant along each edge and one
colour in the middle. That nine-slices exactly.

`SurfaceRegistry::ShadowTile` draws it once at `2·(blur + radius) + band`
square — 104×104 for the default 33 px blur and 14 px radius — and every
window's shadow becomes nine `wlr_scene_buffer`s with source boxes into it.
One terminal: **64.0 → 45.0 MiB**, its 14.0 MiB shadow surface replaced by a
1.2 MiB tile that the next window will not pay for again.

Nine-slicing is usually an approximation and here it is not, which is worth
checking rather than believing: composing the slices on the CPU and comparing
against the same shadow rendered at full size is **identical in every pixel**
at 600×400, 1920×1080, 200×120, at radius 0 (foreign windows, whose corners
nothing can round) and at another blur. A full-desktop capture through the
screenshot portal, old build against new, differs in **3 pixels of 921,600, by
1/255** — floating-point noise in the SDF, not a seam.

Two things the geometry needs and would be silently wrong without: the source
box for a stretched slice is inset two pixels into the band, because a linear
sample at the end of a stretched run reaches past the box it was given; and the
vertical offset is applied by *placing* the tree, not by drawing it into the
tile, because an offset is a translation of the whole picture. The one
approximation left is a window narrower than two corners, where the corner
slices are squeezed rather than the shadow refused.

**Blur happens at half resolution.** The Kawase pyramid's first level and the
capture target were both window-sized, and they are the two largest things a
blurred surface owns — 8.8 of a 1280×720 window's 100 MiB, with both blur kinds
live. Starting the pyramid an octave down costs a quarter of the pixels for
each: **8.8 → 2.3 MiB**, and the compositor's own frost surfaces drop the same
way (LavaTerm's went 5.8 → 1.8 MiB).

It is free in the way downsampling usually is not, because what is being
downsampled is *about to be blurred*: the result is upsampled by a linear
sampler onto a picture with no sharp detail left to lose. Measured against the
same frame at full resolution — the demo's `.blur(radius: 5)` shelf reflections
and its `.backdropBlur(radius: 10)` glass panel — **mean channel delta 1.0–2.3
with a maximum of 23**, and nothing outside the blurred regions moves at all.

The reach of one Kawase iteration doubles in window pixels when the pyramid
moves down an octave, so `iterationsFor`'s ladder starts at 16 px rather than 8:
a given radius asks for one *fewer* pass than it used to and lands at the same
width. Content blur is drawn into the capture target at that scale too —
`QuadRenderer::setSceneTargetScale` shrinks the viewport and the scissors while
the vertex shader still divides by the window size, so the geometry needs no
adjusting. `LAVA_BLUR_SHIFT=0` puts it all back.

**Backdrop frost snapshots are discarded, not cached.** Each refresh uploads a
full-screen texture under `frost:<surface>:<n>`, and `n` only goes up — so the
dormant set was holding every dead one until the 256 MiB byte budget noticed.
Thirteen refreshes now leave one entry and twelve evictions rather than ~95 MiB
of snapshots nothing could ever name again. That is what
`TextureManager::discardTexture` is for; reach for it for any key with a
generation counter in it, and *not* for paths or content hashes, where the
dormant set is a good bet.

## A fullscreen game is scanned out, not composited

Direct scanout hands a client's dmabuf straight to the CRTC. It is what makes
a fullscreen game smooth, and it is also how one paints garbage: the game is
still writing the buffer the display is reading. NVIDIA has never honoured the
implicit `dma_resv` fence, so on that driver "still writing" is not a race
anybody wins.

**`linux-drm-syncobj-v1` is the answer, and it is advertised.** A client
attaches an acquire timeline point to each buffer; wlroots hands it to the
atomic commit as `IN_FENCE_FD` (`backend/drm/atomic.c`), and the CRTC waits for
the client's own GPU work without anyone copying anything. `Output::syncScanoutLock`
therefore composites only what is *not* fenced: it finds the client covering
the output — X11 or Wayland, the question is the same — and holds
`wlr_output_lock_attach_render` while that client's buffer has no acquire
point.

Two things make the fence a trustworthy per-frame signal rather than a flapping
one, and both are worth knowing before "it toggles" is diagnosed again:

- A buffer commit with no acquire point is a **protocol error** once the
  surface has a `wp_linux_drm_syncobj_surface_v1`. A client cannot fence some
  frames and not others.
- wlroots **ignores bufferless commits** when moving the state, so a
  damage-only or frame-callback commit does not clear the fence of the buffer
  that is actually on screen.

Measured with `LAVA_SCANOUT_PROBE=1` against a fullscreen X11 GL client on
Xwayland 24.1 and NVIDIA 610: fenced on **100% of frames** over minutes, in
both software and hardware GL. The compositor used to composite every covering
X11 client regardless, which cost a full-screen render and a whole-output
damage on every frame of every fullscreen game.

The lock is asymmetric on purpose: an unfenced frame locks immediately, and it
takes `kFencedFramesToUnlock` (30) consecutive fenced frames to release, so a
surface swapped out under an X11 window cannot flip the output for a frame.
While locked the damage ring gets the whole frame — Xwayland commits reused
buffers with tiny damage regions, and the other swapchain image would still be
holding the previous camera angle.

## The dock hides only when something is in the way

`SubscribePanelArea` tells a panel whether a window on the current workspace
overlaps its own strip; the dock stays out while nothing does and falls back to
pointer-driven auto-hide when something does. The compositor recomputes on
window moves and resizes as well as on list changes — geometry the window list
deliberately does not carry — and sends only when the answer flips, so dragging
a window across the bottom edge is two messages, not one per motion event.

It is a `bidi_stream` like the other subscriptions, and the IDL says why at
length: a `server_stream` servant in NPRPC is a generator the stream manager
pulls from, and this data is pushed by the compositor's loop. Read that note
before adding another state stream.

## Notifications

The panel is the session's notification daemon: canvas's `NotificationHost`
owns `org.freedesktop.Notifications`, `Notifications` in LavaUI is the
view-model, and `ToastStack` in LavaTaskbar draws the cards at the top right of
the panel's own surface — no second process, no new surface kind, because the
panel already has a full-width one that reaches `MenuSession.openHeight` down
the screen for dropdowns.

Supported: body text, `app_icon` and the `image-data`/`image-path` hints,
urgency (critical is red and never expires), actions as buttons with `default`
on the card body, `replaces_id`, hover to pause the countdown. Capabilities are
reported honestly as `body`, `icon-static`, `actions`, `persistence` — no
markup, so nothing prints `<b>` at the user.

If another daemon already owns the name — dunst, or a desktop this is nested
inside — the panel says so once and shows nothing rather than fighting for it.

Two known edges: the input region is a single rectangle, so while toasts are up
the panel claims a band across the top of the screen rather than only the cards
(`SetInputRegion` would need to take a region for that), and the depth of that
band is estimated from the toast contents rather than measured.

## Starting things with the session

Two layers, and the split is deliberate.

**The desktop's own parts** — panel, dock — are `[shell]` in `lava.conf`, started
and supervised by `ShellSupervisor`: restarted with backoff, abandoned after
enough failures, stopped on the way out. A session without them is broken, so
the compositor treats them as its own.

**The user's programs** — tray applets, an idle inhibitor, a notification
daemon — go in `~/.config/lava/autostart`, a plain shell script run with
`/bin/sh` once the socket, the control plane and the shell are up:

```sh
# ~/.config/lava/autostart
blueman-applet &
nm-applet --indicator &
pasystray &
```

Fire and forget, not supervised: an applet that exits was either told to or is
not installed, and neither improves by being restarted every ten seconds. It
runs after the panel is *spawned* rather than after the tray exists, which is
enough — a StatusNotifierItem re-registers when the watcher appears.

**A nested session does not run it.** Applets are singletons on the session
bus, and the second `nm-applet` either fights the first for the tray or exits.
The test is whether the compositor inherited a `WAYLAND_DISPLAY` or `DISPLAY`,
so headless test runs skip it too.

## Where to change what

| Goal | Start here |
|---|---|
| Widget / layout / state | `Sources/LavaUI/*.swift` |
| Editor correctness / search / undo | `Sources/LavaText` |
| Draw commands / mesh / glyphs | `Sources/LavaUI/DrawList.swift`, `canvas/src/render/draw_command.hpp` |
| Vulkan pipelines / text atlas / images | `canvas/src/render/` |
| Shared draw arena IPC | `canvas/src/ipc/draw_arena.*` |
| Font identity / registration | `canvas/src/render/font_key.*`, `Font.swift`, IDL `RegisterFont` |
| Control-plane API | `idl/lava.npidl` then `scripts/gen_stubs.sh` |
| Compositor windows / input / workspaces | `compositor/src/main.cpp` |
| Compositor config (`lava.conf`) | `compositor/src/config.*`, `compositor/README.md` |
| Window corner rounding | `QuadRenderer::pushCornerMask`, `quad.frag` kind 4 |
| Window shadows (focused only) | `SurfaceRegistry::applyShadow`, `quad.frag` kind 5 |
| Window chrome an app draws itself | `Sources/LavaUI/WindowControls.swift` |
| Pointer image (`.cursor(_:)`) | `Sources/LavaUI/Cursor.swift`, `AppWindow::setCursorShape`, IDL `SetCursor` |
| Draggable panes | `Sources/LavaUI/SplitView.swift` |
| Dropdown / one-of-many switcher | `Sources/LavaUI/ComboBox.swift` |
| Restoring where an editor was | `EditorPosition`, `EditorController.position()/restore(_:)` |
| TraceLoom tabs and workspaces | `Sources/TraceLoomApp/{LogDocument,TraceLoomSession}.swift`, `TraceLoomCore/Workspace.swift` |
| Panel global menu (import side) | `canvas/src/menu/menu_import.*`, `Sources/LavaUI/PanelMenu.swift` |
| Window list / dock | `SubscribeWindows` in the IDL, `Sources/LavaDock/` |
| 3D app switcher | `LavaSwitcher`, launched by Ctrl+Tab / Mod+Tab; live posters via `CaptureSurface` |
| Stream delivery to clients | `StreamPump` in `compositor/src/control_plane.cpp` |
| Why a frame was late | `compositor/src/frame_probe.*` (`LAVA_FRAME_PROBE=1`) |
| When a frame is drawn (pacing) | `SurfaceRegistry::animate`, `Output::on_frame` |
| Frame handover / fences | `DmabufImage::publishFence`, `CanvasSurface::frameFence` |
| Client open / Present / input stream | `Sources/LavaClient/` |
| Scene nodes / renderer-owned scroll + hover | `RenderWindow::scrollScene`, `advanceSceneAnimations`, `DrawList.nodeFlags` |
| Who draws the title bar | `ToplevelDecoration::apply`, `Server::serverDecorated` |
| Window position / maximize restore | `compositor/src/window_memory.*`, `SurfaceRegistry::applyInitialPlacement` |
| Popups / context menus | `Server::on_new_popup`, `Popup::on_commit`, `Server::popupBounds` |
| Which pixels of a surface take input | `point_accepts_input` hooks, `ClientSurface::acceptsInput`, `SetInputRegion` |
| Minimum window size | IDL `SetMinSize`, `SurfaceRegistry::minFor`, `LavaClient.setMinimumSize` |
| Focus, including clicking the desktop | `Server::focusSurface`, `Server::blurAll` |
| Print Screen → clipboard | `Server::requestScreenshot`, `Clipboard::setImagePng` |
| Texture batching / descriptor budget | `QuadRenderer::bindTexture`, `ImageAtlas` |
| Blur (backdrop + content) | `BlurPass`, `quad.frag` kinds 2/6, `DrawList.withBlurScope` |
| Terminal reflow on resize | `TerminalScreen.reflow`, `rowWrapped` |
| Perf scenarios | `Sources/LavaBench/`, `docs/performance.md` |
| App demos | `Sources/HelloWorld/`, Spotify/TraceLoom/LavaTerm apps |

## Conventions agents should follow

1. **Do not** put draw-list pixels on NPRPC. Arenas for geometry; RPC for
   names, surfaces, present, input.
2. **Do not** hand-edit `Sources/LavaIDL/lava.swift` or
   `compositor/src/gen/*` except for a one-off; regenerate from IDL.
3. **Do not** link NPRPC into `LavaUI`. Keep unsafeFlags out of the framework
   package.
4. Prefer **UTF-8 byte offsets** for hot text paths (`LavaText`); grapheme
   walks are O(n) and show up as typing cost on large buffers.
5. Keep pure logic in `LavaText` / `*Core` so tests stay headless.
6. Match existing prose style in this codebase: short comments that explain
   *why*, especially around process boundaries and ownership.
7. After behavior changes that affect frame cost, consider `LavaBench` and
   `docs/performance.md` (work *counts* gate harder than noisy ms).
8. Client input release coordinates use **content** space (title bar offset);
   see compositor cursor release path if clicks “miss” by a constant Y.
9. Verify claims about pixels by rendering and looking, not by reading the
   layout tree. Several bugs here — a clipped row in a scroll container, a
   panel fill painted over everything — are invisible in `layout_tree` and
   obvious in a screenshot.
10. Say plainly what you could not test. Whole classes of behaviour here
    (real pointer input, foreign-window pixels) have no headless path, and a
    confident claim about one of them is a claim nobody checked.

## Docs index

| Doc | Topic |
|---|---|
| `README.md` | Build, run, depend on LavaUI from another package |
| `docs/api.md` | Application-facing LavaUI API |
| `docs/performance.md` | LavaBench design and baselines |
| `docs/agent.md` | Runtime agent TCP / MCP control plane |
| `docs/client-server-gaps.md` | Client vs host feature gaps |
| `docs/retained-scene-tree.md` | Retained tree / invalidation notes |
| `docs/nprpc-client-stream-gap.md` | Historical SHM stream bug (resolved) |
| `docs/install.md` | Debian/Arch bootstrap, NPRPC, Docker, QEMU VM |
| `compositor/README.md` | Compositor + optional VM workflow |
| `idl/lava.npidl` | Control plane contract (authoritative) |
