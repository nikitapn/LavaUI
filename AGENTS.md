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

- **Colours are sRGB** (picker / hex / `Color(r:)`). Vertex shaders
  linearise (`srgb.glsl`) before blending; the swapchain encodes on the way
  out, so `Color(r: 0.5)` is `#800000` on screen. They used to be written
  as linear and encoded twice — `0.28` arrived looking like `0.56` and a
  palette from a colour wheel came out pastel. Palettes authored against
  that will read darker until retuned. Do not pre-linearise in
  `Color.rgba8` or the attachment encodes twice again.
- **Blending happens in linear light, so alpha does not mean what CSS means
  by it.** Every attachment is `*_SRGB`, so a translucent black at `a=0.9`
  lets through 0.27 where a browser would show 0.08 — the useful range of a
  window wash is 0.98–1.0, not 0.8–1.0. This is not alpha being encoded
  (it never is, anywhere); it is the colours it was blended against being
  linear. Same reason text coverage is deliberately bent in `quad.frag`, and
  the reason a translucency tuned under one wlroots renderer is wrong under
  the other. **Read `docs/colour-and-blending.md` before picking any alpha
  value** — it has the numbers, the comparison to other toolkits, and what
  changed for `Scene3D` when its lighting stopped multiplying authored
  components (shadows lifted; scenes tuned before 2026-08-14 want less
  ambient, not more).
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

Without nprpc, the package still builds; control-plane products
(`LavaClient`, full client mode) are gated on detecting `nprpc_swift`.

## Repo map

```text
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
scripts/           RPC stub generation
Tests/             Headless Swift tests (no GPU required for most)
```

**Dependency hygiene (enforced by Package.swift):**

- `LavaText` / `LavaMenu` / `*Core` targets have **no** engine dependency.
- `LavaUI` must stay free of NPRPC **unsafeFlags** so it can be a GitHub
  package. Control plane sits in `LavaClient` / `LavaIDL` above the framework.

## Build and test

```bash
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
| Move the real cursor / click the desktop, drag a window edge, right-click for a popup | headless wlroots has no input devices, and there is no virtual-pointer protocol | drive the app's own agent port, or ask the human |
| Screenshot foreign (GTK/Chromium) windows from *grim* | no screencopy protocol implemented, so `grim` cannot attach | Print Screen copies the output under the cursor to the clipboard as PNG. `CaptureSurface` reads a foreign window's last buffer (shm map or `wlr_texture_read_pixels`); the 3D switcher uses that. |
| See overlay content from the agent | `find`/`layout_tree` walk the main tree; a presented overlay's subtree is detached | click by coordinate |
| Reach the compositor's scene scroll from a client's agent | agent input is injected into that client's engine | test scene-level behaviour in **windowed** mode, where the app owns the renderer |

Windowed mode under a nested compositor is fragile in one known way: if the
compositor clamps the window to a size the app did not request, the swapchain
can hit `VK_ERROR_OUT_OF_DATE_KHR` on acquire and the engine treats it as
fatal. Open at the size the output will actually grant to avoid it.

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
| `compositor/README.md` | Compositor + optional VM workflow |
| `idl/lava.npidl` | Control plane contract (authoritative) |
