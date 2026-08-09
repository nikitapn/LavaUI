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
  LavaIDL/         Generated NPRPC Swift stubs (do not hand-edit long-term)
  LavaBench/       Perf suite vs committed baseline
  LavaSurface/     Client: wallpaper / desktop surface
  LavaTaskbar/     Client: panel / taskbar
  HelloWorld/      Demo playground + FBD bits
  LavaTerm*/       Terminal emulator (core headless + app)
  Spotify*/        LavaSpotify (core headless + app)
  TraceLoom*/      Log / trace viewer + Ollama assistant
  ArenaDemo/       Multi-client / arena experiments
  FBDModel/        Function-block diagram model
canvas/            C++ Vulkan engine + Yoga (SwiftPM C++ targets)
compositor/        wlroots compositor + canvas surfaces + control plane
idl/lava.npidl     Control-plane IDL
docs/              Design notes, API, performance, gaps
tools/             Agent CLI / MCP over LAVA_AGENT_PORT
scripts/           gen_stubs.sh, run-host-client.sh
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
| `CANVAS_VK_VALIDATION=1` | Vulkan validation layers |
| `NPRPC_SWIFT_PATH` | Override path to `nprpc_swift` package |
| `NPRPC_ROOT` / `NPRPC_BUILD_DIR` | In-tree nprpc link for Swift bridge |

Runtime agent protocol (MCP/CLI, stable `sid`s, hit-testing): **`docs/agent.md`**.

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
| Window chrome an app draws itself | `Sources/LavaUI/WindowControls.swift` |
| Panel global menu (import side) | `canvas/src/menu/menu_import.*`, `Sources/LavaUI/PanelMenu.swift` |
| Client open / Present / input stream | `Sources/LavaClient/` |
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
