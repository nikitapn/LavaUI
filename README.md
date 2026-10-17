# LavaUI

A declarative UI framework for Swift on Linux, with its own GPU renderer — and
a Wayland desktop built on top of it.

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

If you have written SwiftUI, this will look familiar: views are small structs
with a `body`, state lives in `@State`, and the framework redraws what changed.
Everything underneath — layout, text, rendering — is part of this repository.

The repo has two halves:

- **The framework** (`LavaUI`) — for writing desktop apps in Swift.
- **The Lava desktop** — a Wayland compositor with a panel, dock, launcher and
  a set of apps, all written with LavaUI. Ordinary Linux apps run on it too.

Linux only for now.

## Quick start

On Debian or Arch:

```bash
git clone https://github.com/nikitapn/LavaUI.git && cd LavaUI
./scripts/bootstrap.sh --yes      # installs everything, builds everything
swift run HelloWorld              # the demo
```

[docs/install.md](docs/install.md) explains what that does, and how to install
only what the framework needs.

## Using LavaUI in your app

Add the package to your `Package.swift` and open a window:

```swift
import LavaUI

@main
struct MyApp {
    static func main() {
        guard let editor = LavaApp.open(title: "My App") else { return }
        LavaApp.run(editor: editor) {
            Text("hello from LavaUI", color: .accent)
        }
    }
}
```

**[Getting started](docs/getting-started.md)** walks through it from an empty
directory, including the one manifest setting the package needs.

## Apps

Every one of these is a LavaUI app and runs with `swift run <name>`:

| App | What it is |
|---|---|
| `HelloWorld` | Demo of the framework's views |
| `LavaTerm` | Terminal emulator |
| `LavaEditor` | Text editor |
| `LavaExplorer` | File manager — tabs, split panes, Trash |
| `LavaView` | Image viewer |
| `LavaPDF` | PDF reader |
| `LavaPlayer` | Video player |
| `LavaSpotify` | Spotify player |
| `LavaWeather` | Weather |
| `TraceLoom` | Log viewer with an AI assistant |
| `LavaShot` | Screenshot and annotation tool *(needs the Lava desktop)* |

The desktop itself — `LavaPanel`, `LavaDock`, `LavaLauncher`, `LavaSwitcher`,
`LavaSettings` — is made of LavaUI apps as well.

## The Lava desktop

```bash
compositor/scripts/dev-run                       # try it in a window, inside your current session
compositor/scripts/start-lava-compositor setup   # install it as a real session
```

See [compositor/README.md](compositor/README.md).

## Documentation

| | |
|---|---|
| [Getting started](docs/getting-started.md) | From an empty package to a running window |
| [API guide](docs/api.md) | Views, layout, modifiers, theming, animation |
| [SwiftUI parity](docs/swiftui-parity.md) | What carries over from SwiftUI and what differs |
| [How it works](docs/architecture.md) | The rendering pipeline and the repo layout |
| [Installing](docs/install.md) | Packages, Docker, the test VM |
| [Performance](docs/performance.md) | Benchmarks and baselines |
| [AGENTS.md](AGENTS.md) | The in-depth guide for contributors and coding agents |

The docs site is at [lavaui.nikitapn.com](https://lavaui.nikitapn.com).

## Built with

- **Swift 6** with C++ interop, and **C++23** for the engine and compositor
- **Vulkan** — rendering
- **Yoga** — flexbox layout
- **FreeType** and **HarfBuzz** — fonts and text shaping
- **GLFW** — windows, when an app runs on its own
- **wlroots** — the compositor
- **NPRPC** — communication between apps and the compositor
- **poppler** (PDF), **libmpv** (video), **libarchive** (archives),
  **librsvg** (icons)

The full package lists are in [packaging/deps/](packaging/deps/).

## License

MIT — see [LICENSE](LICENSE).
