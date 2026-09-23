# Getting started

LavaUI is a declarative UI framework in Swift. Views are written the way
SwiftUI writes them: a `body` of nested value types, `@State`, stacks and
modifiers. Everything under them belongs to LavaUI: Yoga lays them out,
HarfBuzz and FreeType shape and rasterize the text, and one Vulkan pipeline
draws the result.

This page takes you from an empty directory to a running window. The
[API guide](api.md) covers the rest.

## What you need

LavaUI runs on Linux only for now. You need:

- a Swift 6.3 toolchain,
- a working Vulkan driver (`vulkan-radeon`, `vulkan-intel` or `nvidia-utils`),
- the development packages for GLFW, FreeType, HarfBuzz and, for global menus,
  GLib and libdbusmenu-glib.

On Debian or Arch, the repository's scripts install all of it:

```bash
git clone https://github.com/nikitapn/LavaUI.git
cd LavaUI
./scripts/install-deps.sh --yes     # system packages
./scripts/install-swift.sh          # the toolchain, if you have none
./scripts/check-env.sh              # what the build can see
```

[Installing LavaUI](install.md) covers the details, including Docker images
and the full desktop (compositor, NPRPC).

A quick way to check the setup is to run the demo from the clone:

```bash
swift run HelloWorld
```

## A new package

```bash
mkdir MyApp && cd MyApp
swift package init --type executable
```

Replace `Package.swift` with this:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v13)], // ignored on Linux; keeps the manifest valid
    dependencies: [
        .package(url: "https://github.com/nikitapn/LavaUI.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "LavaUI", package: "LavaUI"),
            ],
            swiftSettings: [
                // Required: LavaUI calls its C++ engine through C++ interop.
                .interoperabilityMode(.Cxx),
            ]
        ),
    ],
    // Match the engine, which uses C++23.
    cxxLanguageStandard: .gnucxx2b
)
```

SwiftPM builds the C++ engine and Yoga from the same checkout, so you need no
Meson, Ninja or prebuilt library. To work against a local clone instead, use
`.package(path: "../LavaUI")`.

## A first window

Put this in `Sources/MyApp/main.swift`, replacing the generated file:

```swift
import Foundation
import LavaUI

struct Counter: View {
    @State private var count = 0

    var body: some View {
        VStack(padding: 16, spacing: 8) {
            Text("Count: \(count)", color: .accent)
            HStack(spacing: 8) {
                Button("Increment") { count += 1 }
                Button("Reset") { count = 0 }
            }
        }
    }
}

guard let editor = LavaApp.open(title: "My App", width: 480, height: 320) else {
    exit(1)
}
LavaApp.run(editor: editor) {
    Counter()
}
```

Then build and run it:

```bash
swift run MyApp
```

The first build takes a few minutes because it compiles the engine. Later
builds compile only what changed.

`LavaApp.open` creates the window, the Vulkan device and the default fonts.
`LavaApp.run` owns the loop until the window closes. The loop is frame-driven:
changing `count` marks the view dirty, and the next frame recomputes only the
`body` that read it. An idle window costs nothing, because the loop sleeps
until input arrives.

## Lists and input

`ForEach` needs a stable key. A plain `for` loop is not allowed in a
`body`, because identity by index breaks when rows move. `TextField` binds to
state through `$`:

```swift
struct Todo: Identifiable {
    let id = UUID()
    var title: String
}

struct TodoList: View {
    @State private var items: [Todo] = []
    @State private var draft = ""

    var body: some View {
        VStack(padding: 16, spacing: 8) {
            TextField(text: $draft, placeholder: "New item", onSubmit: add)
            ForEach(items) { item in
                Text(item.title)
            }
        }
    }

    private func add() {
        guard !draft.isEmpty else { return }
        items.append(Todo(title: draft))
        draft = ""
    }
}
```

For state that code outside the view tree also uses, such as a menu or a
network client, use an `@Observable` class and `@Bindable`. See
[State and bindings](api.md#state-and-bindings).

## Images and other assets

LavaUI ships its own fonts and shaders. Your images belong to your target:

```swift
// Package.swift, on the MyApp target:
resources: [.process("Resources")],
```

```swift
let logo = ImageStore.loadAsset(named: "logo.png", bundle: .module, into: editor)
```

Load assets after `LavaApp.open` and before `LavaApp.run`, and pass them into
the root view.

## On the Lava desktop

The same app can also run as a client of the Lava compositor. It then has no
window, no GPU and no Vulkan device of its own: it lays out and writes its
draw list into shared memory, and the compositor draws it. To support both
modes, depend on `LavaHost` as well and open through it:

```swift
import LavaHost

guard let editor = LavaHost.open(title: "My App") else { exit(1) }
LavaHost.run(editor: editor) { Counter() }
```

`LavaHost` picks the client when `LAVA_CLIENT=1` is set and a local window
otherwise. The client needs the NPRPC library. The
[API guide](api.md#running-under-the-compositor) explains what changes between
the two modes.

## Where next

- [API guide](api.md): layout, modifiers, the built-in views, overlays,
  `Canvas`, `Scene3D`, theming and animation.
- [SwiftUI parity](swiftui-parity.md): what carries over from SwiftUI, and
  what is different.
- [Colour and blending](colour-and-blending.md): read this before choosing an
  alpha.
- [Native menus](native-menus.md): application menus, including the global
  menu on the Lava panel.
- [Agent control](agent.md): drive a running app over TCP, including layout
  queries, input and screenshots.
- The API reference, generated from the source, is in the sidebar.
