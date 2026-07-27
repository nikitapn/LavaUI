# Architecture (post–SwiftCrossUI)

## Direction

The interactive product is a **single GLFW + Vulkan window**.  
SwiftCrossUI / Gtk are **out** of the interactive path.

| Layer | Tech | Owns |
|--------|------|------|
| Domain model | **Swift `FBDModel`** | Blocks, wires, types |
| Declarative UI | **Swift `UI` + `UINode`** | Widget tree, `onClick` handlers |
| App launcher | **Swift `HelloWorld`** | Commit tree, seed diagram, poll events |
| Engine | **C++ `libcanvas`** | Vulkan, Yoga, TextRenderer, hit-test, event queue |
| Layout | **Yoga** | Flex on the C++ widget tree |
| Errors | `canvas::Result` / `std::expected` | Cross-boundary failures |

---

## From hardcoded `drawAppShell` → declarative Swift tree

### Goal

Replace ImGui-authored chrome (tree / properties panels) with a **SwiftUI-shaped
description** that C++ lays out (Yoga), draws (TextRenderer — not ImGui for
labels), and hit-tests. Events flow back into Swift `onClick`.

```
Swift UI tree  ──commit──►  C++ WidgetTree  ──Yoga──►  rects
       ▲                         │
       │                    TextRenderer draw
       │                    hit-test on click
       └──── poll events ────────┘
```

### Split of responsibilities

| Concern | Where |
|---------|--------|
| What the UI *is* (structure, text, colors, handlers) | **Swift** |
| How it is *laid out* (flex, measure text) | **C++ Yoga** |
| How it is *drawn* (glyphs) | **C++ TextRenderer** |
| Hit testing | **C++** (laid-out rects) |
| `onClick` / app logic | **Swift** (handlers keyed by widget id) |

ImGui remains only for the **menu bar** (and the legacy path if no UI tree is
committed). `CanvasTextWidget` (ST editor) stays ImGui-draw-list for now.

### Widget kinds (v1)

| Kind | Role |
|------|------|
| `Row` / `Column` | Flex containers (`HStack` / `VStack`) |
| `Text` | Label via TextRenderer; optional `clickable` |
| `Spacer` | `flexGrow` filler |
| `DiagramHost` | Marks the center rect → `diagramViewport_` (FBD scene) |

### Event model (no C++ → Swift function pointers)

C++ cannot reliably hold Swift closures. Instead:

1. Swift assigns `id > 0` to clickable widgets and stores `handlers[id]`.
2. On mouse down, C++ hit-tests and **enqueues** `{widgetId, Click}`.
3. Swift main loop: `editor.dispatchUIEvents(ui:)` → `handlers[id]?()`.

### Structural hot update (tree hot-reload)

**Today:** any Swift state change rebuilds the description and
`editor.commitUI(root, ui:)` — full tree swap under the engine mutex. Cheap
for editor chrome (tens of nodes).

```swift
ui.beginCommit()
let root = ui.HStack { ... }
editor.commitUI(root, ui: ui)   // atomic swap on C++ side
```

**Later (source hot reload):** load a Swift plugin dylib that exports
`buildChrome(model:) -> UINode`, or a watch + `swift build` + process restart.
The commit path above stays the same; only the *source* of the tree changes.

### Migration ladder

1. **Now:** `Text` + stacks + `DiagramHost`; HelloWorld builds full chrome in Swift.
2. Next: panel backgrounds, separators, scroll regions as Yoga widgets.
3. Next: selection styling, hover, focus ring (still TextRenderer / geometry).
4. Later: migrate ST field off ImGui; drop legacy `drawAppShell` panels entirely.
5. Optional: diffing/reuse of Yoga nodes (only if commit cost shows up).

---

## Swift API sketch

```swift
let ui = UI()
ui.beginCommit()
let root = ui.HStack(padding: 4) {
    ui.VStack(width: 220, padding: 8) {
        ui.Text("Project", r: 0.7, g: 0.75, b: 0.9)
        ui.Text("  AND_1", onClick: { select("and1") })
    }
    ui.DiagramHost()
    ui.VStack(width: 260, padding: 8) {
        ui.Text("Properties")
        ui.Text("Name: AND_1")
    }
}
editor.commitUI(root, ui: ui)

// main loop
while editor.isOpen {
    editor.dispatchUIEvents(ui: ui)
    if stateChanged { /* rebuild + commitUI */ }
}
```

Builder free functions (C++ interop):

```
uiReset → uiBegin/uiText/uiEnd… → uiCommit
uiPollEvent → (widgetId, kind)
```

---

## Run

```bash
cd canvas && ninja -C .build.Debug
cd .. && swift run HelloWorld
```

Assets: `canvas/.build.Debug` (or `CANVAS_ASSETS_ROOT`).

## C++ interop surface

- `swift_editor.hpp` — free functions + opaque `SwiftEditor*`
- `shell/widget.hpp` — `WidgetTree`, `WidgetBuilder`, events
- Incomplete C++ types import as `OpaquePointer` in Swift
