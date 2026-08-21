# LavaUI

A declarative UI framework in Swift, rendering through Vulkan.

The current application-facing API is documented in
**[docs/api.md](docs/api.md)**. Coding agents: start from
**[AGENTS.md](AGENTS.md)** (architecture, layout, build, conventions).

Views are described the way SwiftUI describes them — a `body` returning nested
value types — but the whole stack underneath is here: layout via Yoga, text via
HarfBuzz and FreeType, and a single Vulkan pipeline that draws everything.

```swift
struct Counter: View {
    @State private var count = 0

    var body: some View {
        VStack(padding: 8) {
            Text("count: \(count)", color: .accent)
            Text("[ increment ]", onClick: { count += 1 })
        }
    }
}
```

## Building

On a clean Debian or Arch machine the whole stack — packages, wlroots 0.19,
NPRPC, compositor, Swift clients — is:

```bash
./scripts/bootstrap.sh --yes          # or --release
./scripts/check-env.sh                # what the build can see
```

That is documented in **[docs/install.md](docs/install.md)** (Docker images
and the QEMU install-test VM live there too). The short form if the
packages are already on the machine:

```bash
swift build                   # Swift + C++ canvas engine (SwiftPM compiles both)
swift run HelloWorld          # demo
swift run LavaSpotify         # music player (see docs/lavaspotify.md)
swift run LavaTerm            # terminal emulator (click the grid, type)
swift test                    # headless tests, no GPU needed
```

System packages: Vulkan, GLFW, FreeType, HarfBuzz (and on Linux for global
menus: GLib + libdbusmenu-glib). No Meson/Ninja — SwiftPM builds the C++
engine.

Linux only today.

## Using LavaUI in a new project

LavaUI is a normal SwiftPM product of this repo. SwiftPM also builds the nested
`canvas` package (C++ engine + shader resources) from the same checkout — you
only declare a dependency on **this** repository.

### 1. System packages (Linux)

```bash
./scripts/install-deps.sh --yes     # Debian/Ubuntu or Arch; see packaging/deps/
```

The compositor and NPRPC need more than the engine (wlroots 0.19, Boost,
 dbusmenu, rsvg, …). `install-deps.sh` is the list. A windowed
LavaUI app that will never talk to the compositor can get by with Vulkan,
GLFW, FreeType, HarfBuzz and libdbusmenu-glib alone.

You also need a working Vulkan ICD (e.g. `vulkan-radeon`, `nvidia-utils`,
`vulkan-intel`) and a Swift 6.3 toolchain (`scripts/install-swift.sh`).

### 2. Scaffold an executable package

```bash
mkdir MyApp && cd MyApp
swift package init --type executable
```

### 3. Depend on LavaUI from GitHub

Edit `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v13)], // ignored on Linux; keeps the manifest valid
    products: [
        .executable(name: "MyApp", targets: ["MyApp"]),
    ],
    dependencies: [
        // Prefer a tag once you pin releases:
        // .package(url: "https://github.com/nikitapn/LavaUI.git", from: "0.1.0"),
        .package(url: "https://github.com/nikitapn/LavaUI.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                // Package identity = last path component of the URL ("LavaUI").
                .product(name: "LavaUI", package: "LavaUI"),
            ],
            swiftSettings: [
                // Required: LavaUI talks to the C++ engine via C++ interop.
                .interoperabilityMode(.Cxx),
            ]
        ),
    ],
    // Match the engine (std::expected / C++23).
    cxxLanguageStandard: .gnucxx2b
)
```

Local clone instead of GitHub:

```swift
.package(path: "../LavaUI"),  // folder name becomes the package id
// then: .product(name: "LavaUI", package: "LavaUI")
```

### 4. Minimal `main`

Replace the generated source with something like
`Sources/MyApp/MyApp.swift`:

```swift
import Foundation
import LavaUI

@main
struct MyApp {
    static func main() {
        guard let editor = LavaApp.open(title: "My App") else {
            exit(1)
        }
        LavaApp.run(editor: editor) {
            VStack(padding: 12) {
                Text("hello from LavaUI", color: .accent)
            }
        }
    }
}

```

### 5. Build and run

```bash
swift build
swift run MyApp
```

SwiftPM will fetch this repo (including `canvas/`), compile Yoga + the Vulkan
engine, pack checked-in SPIR-V and default fonts, and link system libraries via
pkg-config. You do **not** need Meson, Ninja, or a prebuilt `libcanvas`.

### App-owned assets

Framework fonts and engine shaders ship with LavaUI / canvas. **Your** images
belong on your executable:

```swift
// Package.swift — on the MyApp target:
resources: [
    .process("Resources"),
],

// Load at runtime:
let icon = ImageStore.loadAsset(
    named: "icon.png",
    bundle: .module,
    into: editor
)
```

Put files under `Sources/MyApp/Resources/`.

## The compositor

The repo has a second half: a **Wayland compositor** under `compositor/` —
C++23 on wlroots 0.19 — that runs a desktop of LavaUI apps, and everything else
Linux runs alongside them through xdg-shell and Xwayland.

```bash
compositor/scripts/dev-run       # nested in the Wayland session you are in
compositor/scripts/dev-run -H    # headless, software rendering, no window
compositor/scripts/dev-run -r    # release build, compositor and shell alike
compositor/scripts/dev-run -- env LAVA_CLIENT=1 ./.build/debug/LavaTerm
compositor/scripts/start-lava-compositor setup   # a real session, on a real GPU
```

The compositor's own README (**[compositor/README.md](compositor/README.md)**).

## How it works

**[How LavaUI draws](https://claude.ai/code/artifact/37c3ea4e-9060-4466-b733-aba3fcdc5dad?org=ffa809c6-f386-4865-a70f-7a16c5df3b89)**

**The view tree is retained; the draw list is immediate.**

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

**The loop is frame-driven, not event-driven.** A state change sets a dirty
flag; nothing walks the graph synchronously. The loop blocks in
`glfwWaitEvents` until input arrives, so an idle window costs nothing.

**Everything draws through one ordered batch stream.** Rectangles, rounded
rectangles, circles, stroked segments and glyphs share the quad pipeline:
shapes use a rounded-box signed distance field and glyphs sample an R8 atlas.
Large connected polylines switch to a dedicated `LINE_STRIP` pipeline and then
switch back without leaving the stream. Paint order remains emission order — a
caret can cover its own glyphs and a popup can cover a chart. Batches break on
scissor, texture, or pipeline changes.

**Swift owns everything above the pixels.** Layout, hit testing, text shaping,
and input routing are Swift. C++ receives a draw command buffer and knows
nothing about widgets. The rule for what stays in C++: *retain what is
expensive to build and keyed by content* (the glyph atlas, Vulkan objects);
*re-emit everything keyed by position or structure*.

## Layout of the repo

| Target | Contains | Depends on |
|---|---|---|
| `LavaText` | Editing logic: cursors, selection, undo, word/line navigation, soft wrap, syntax rules, search | nothing |
| `LavaMenu` | Application menu IR + declarative DSL (`MenuBar` / `MenuItem`); no drawing | nothing |
| `LavaUI` | Views, Yoga layout, draw list, fonts, input, theming | `LavaText`, `LavaMenu`, `CxxCanvas`, `CYoga` |
| `HelloWorld` | Demo app (`DemoExample`) and an FBD diagram editor | `LavaUI`, `FBDModel` |
| `LavaSwitcher` | 3D Ctrl+Tab / Mod+Tab app switcher (live window posters) | `LavaUI`, `LavaClient` |
| `LavaSpotify` / `SpotifyApp` | LavaSpotify UI + Connect control of spotifyd | `LavaUI`, `SpotifyCore` |
| `SpotifyCore` | Spotify Web API, OAuth, cover download (no Vulkan) | nothing |
| `LavaTerm` / `LavaTermApp` | Terminal emulator (PTY + ANSI + Canvas grid) | `LavaUI`, `LavaTermCore` |
| `LavaTermCore` | VT grid + ANSI parser (headless, unit-tested) | nothing |
| `canvas/` (package) | C++ engine (`CxxCanvas`) + Yoga (`CYoga`), built by SwiftPM | system Vulkan/GLFW/FreeType/HarfBuzz |
| `compositor/` | Wayland compositor and control-plane servant — C++23, built by **meson** rather than SwiftPM | wlroots 0.19, `canvas/`, NPRPC |
| `LavaTaskbar` `LavaDock` `LavaLauncher` `LavaSettings` `LavaDebug` | The desktop shell — panel, dock, launcher, settings, GPU inspector. Ordinary LavaUI clients, with no privileges the demo does not have | `LavaUI`, `LavaClient` |

`LavaText` and `LavaMenu` having **no dependencies at all** is deliberate:
editing logic and menu IR are where fiddly correctness lives, and keeping them
out of reach of Vulkan and C++ interop means they are tested headlessly. That
is enforced by the build graph rather than by discipline.