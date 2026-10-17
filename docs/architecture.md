# How LavaUI works

A longer, illustrated version is on the site:
**[How LavaUI draws](https://lavaui.nikitapn.com/article/how-lavaui-draws)**.
Contributors (human or agent) should also read [AGENTS.md](../AGENTS.md),
which covers the compositor, the control plane and the renderer in depth.

## The view tree is retained; the draw list is immediate

A `View` is a struct rebuilt whenever something changes. Behind it sits a
persistent node tree that owns identity, `@State` storage, Yoga nodes, cached
text measurements, and observation subscriptions. Rebuilding a view does not
rebuild that tree — it reconciles against it.

Identity is **structural**: the tree's shape is encoded in its types, so
`TupleView<Text, Button>` reconciles positionally with no keys and no diffing.
Only `EitherView` (an `if`) and `ForEach` (keyed) need real reconciliation.

Each frame that something changed:

```
body recompute (only nodes whose observed state changed)
  → Yoga layout (only dirty subtrees)
    → draw list emission (a flat POD buffer)
      → one Vulkan pipeline, in index order
```

## The loop is frame-driven, not event-driven

A state change sets a dirty flag; nothing walks the graph synchronously. The
loop blocks waiting for events until input arrives, so an idle window costs
nothing.

## Everything draws through one ordered batch stream

Rectangles, rounded rectangles, circles, stroked segments and glyphs share the
quad pipeline: shapes use a rounded-box signed distance field and glyphs sample
an R8 atlas. Large connected polylines switch to a dedicated `LINE_STRIP`
pipeline and then switch back without leaving the stream. Paint order remains
emission order — a caret can cover its own glyphs and a popup can cover a
chart. Textures are bindless, so batches break only on scissor or pipeline
changes.

## Swift owns everything above the pixels

Layout, hit testing, text shaping, and input routing are Swift. C++ receives a
draw command buffer and knows nothing about widgets. The rule for what stays in
C++: *retain what is expensive to build and keyed by content* (the glyph atlas,
Vulkan objects); *re-emit everything keyed by position or structure*.

## Two ways to run

An app either owns a window and renders with its own Vulkan device, or runs as
a client of the Lava compositor (`LAVA_CLIENT=1`): it lays out and writes its
draw list into shared memory, and the compositor — which owns the GPU — draws
it. The same app code runs both ways; see
[Getting started](getting-started.md#on-the-lava-desktop).

## Layout of the repo

| Target | Contains | Depends on |
|---|---|---|
| `LavaText` | Editing logic: cursors, selection, undo, word/line navigation, soft wrap, syntax rules, search | nothing |
| `LavaMenu` | Application menu IR + declarative DSL (`MenuBar` / `MenuItem`); no drawing | nothing |
| `LavaUI` | Views, Yoga layout, draw list, fonts, input, theming | `LavaText`, `LavaMenu`, `CxxCanvas`, `CYoga` |
| `HelloWorld` | Demo app (`DemoExample`) and an FBD diagram editor | `LavaUI`, `FBDModel` |
| `LavaSwitcher` | 3D Ctrl+Tab / Mod+Tab app switcher (live window posters) | `LavaUI`, `LavaClient` |
| `LavaSpotify` / `SpotifyApp` | LavaSpotify UI + MPRIS control of spotifyd | `LavaUI`, `SpotifyCore`, `LavaMpris` |
| `SpotifyCore` | Spotify Web API, OAuth, cover download (no Vulkan) | nothing |
| `LavaTerm` / `LavaTermApp` | Terminal emulator (PTY + ANSI + Canvas grid) | `LavaUI`, `LavaTermCore` |
| `LavaTermCore` | VT grid + ANSI parser (headless, unit-tested) | nothing |
| `LavaView` / `LavaViewApp` | Image viewer: fit / original size, wheel zoom at the cursor, the folder as a cycle, rotate and save | `LavaUI`, `LavaViewCore` |
| `LavaViewCore` | Folder ordering, viewport arithmetic, pixel rotation, save-format choice (no Vulkan) | nothing |
| `LavaPDF` / `LavaPDFApp` | PDF reader: pages rasterised by poppler in tiles on worker threads, selection, copy, find, outline and links | `LavaUI`, `LavaHost`, `LavaPDFCore` |
| `LavaPDFCore` | The document through poppler's C API, page layout, tile grid, viewport, text selection, outline (no Vulkan) | `CLavaPDF` (poppler) |
| `LavaPlayer` / `LavaPlayerApp` | Video player on libmpv: frames rendered into dma-bufs on the compositor's GPU, subtitle and audio tracks, fullscreen controls | `LavaUI`, `LavaHost`, `LavaPlayerCore`, `CLavaVideo` (mpv, EGL, GBM) |
| `LavaPlayerCore` | Playlist and folder order, the clock, media and subtitle formats, track labels (no Vulkan) | nothing |
| `LavaShot` / `LavaShotApp` | Screenshot tool: freezes the screen, select a region, annotate, copy or save. Client mode only | `LavaUI`, `LavaHost`, `LavaShotCore` |
| `LavaShotCore` | Selection geometry, the annotation document, toolbar actions (no Vulkan) | nothing |
| `canvas/` (package) | C++ engine (`CxxCanvas`) + Yoga (`CYoga`), built by SwiftPM | system Vulkan/GLFW/FreeType/HarfBuzz |
| `compositor/` | Wayland compositor and control-plane servant — C++23, built by **meson** rather than SwiftPM | wlroots 0.19, `canvas/`, NPRPC |
| `LavaPanel` `LavaDock` `LavaLauncher` `LavaSettings` `LavaDebug` | The desktop shell — panel, dock, launcher, settings, GPU inspector. Ordinary LavaUI clients, with no privileges the demo does not have | `LavaUI`, `LavaClient` |

`LavaText` and `LavaMenu` having **no dependencies at all** is deliberate:
editing logic and menu IR are where fiddly correctness lives, and keeping them
out of reach of Vulkan and C++ interop means they are tested headlessly. That
is enforced by the build graph rather than by discipline.
