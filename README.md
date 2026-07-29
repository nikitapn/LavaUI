# LavaUI

A declarative UI framework in Swift, rendering through Vulkan.

Views are described the way SwiftUI describes them — a `body` returning nested
value types — but the whole stack underneath is here: layout via Yoga, text via
HarfBuzz and FreeType, and a single Vulkan pipeline that draws everything. No
GTK, no Qt, no ImGui in the widget path.

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

## Layout of the repo

| Target | Contains | Depends on |
|---|---|---|
| `LavaText` | Editing logic: cursors, selection, undo, word/line navigation, soft wrap, syntax rules, search | nothing |
| `LavaUI` | Views, Yoga layout, draw list, fonts, input, theming | `LavaText`, `CxxCanvas`, `CYoga` |
| `HelloWorld` | Demo app (`DemoExample`) and an FBD diagram editor | `LavaUI`, `FBDModel` |
| `canvas/` | C++ engine: Vulkan, glyph atlas, windowing | — |

`LavaText` having **no dependencies at all** is deliberate: editing logic is
where the fiddly correctness lives, and keeping it out of reach of Vulkan and
C++ interop means it is tested headlessly. That is enforced by the build graph
rather than by discipline.

## Building

```bash
cd canvas && ninja -C .build.Debug     # C++ engine
cd .. && swift build                   # Swift
swift run HelloWorld                   # demo
swift test                             # 82 tests, no GPU needed
```

Linux only today. `CxxCanvas`/`CYoga` are gated on it, and the engine is
GLFW + Vulkan.

## How it works

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

**Everything draws through one pipeline.** Rectangles, rounded rectangles,
circles, stroked lines and glyphs are all quads: shapes use a rounded-box
signed distance field, glyphs sample an R8 atlas. Because there is one pass,
paint order *is* emission order — a caret can cover its own glyphs, a popup can
cover a label. Batches break only on scissor changes.

**Swift owns everything above the pixels.** Layout, hit testing, text shaping,
and input routing are Swift. C++ receives a draw command buffer and knows
nothing about widgets. The rule for what stays in C++: *retain what is
expensive to build and keyed by content* (the glyph atlas, Vulkan objects);
*re-emit everything keyed by position or structure*.

## What exists

**Containers** `HStack` `VStack` `Spacer` `ForEach` `ScrollView` — flexbox via
Yoga, with `if`/`else` and optionals handled by the view builder.

**Content** `Text` (hover, click, wrapping) · `Image` · `DiagramHost`
· `Button` (animated press and hover)

**Input** `TextField` (single and multi-line, soft wrap, selection, clipboard,
undo) · `EditorView` (line-number gutter, syntax rules, current-line highlight,
find, vertical and horizontal scrolling)

**Modifiers** `.padding()` `.background()` `.cornerRadius()` `.frame()`
`.flexGrow()` — chains collapse onto the content's own node, so styling costs
no extra layout boxes unless the content is a fragment.

**Animation** `Animated<T>` interpolates on the *node*, so a press or hover
costs a draw-list re-emit and no `body` recompute. `FrameScheduler` holds the
earliest wake any component asked for; `InvalidationLevel` decides how much of
body → layout → emit actually has to run.

**System** `@State` + `@Binding` with `Observation` · `Theme` (semantic tokens,
light and dark) · focus, hover, pointer capture, click counting · content
scaling

**Text** is grapheme-correct throughout. Cursors are `String.Index`, never
integers, so an arrow key steps over an emoji ZWJ sequence as one unit. Caret
positions map through HarfBuzz clusters, so ligatures and combining marks
behave. Shaping happens once, in Swift, and feeds both layout and drawing —
what is measured cannot drift from what is drawn.

## What is missing

Honest list, roughly in the order it hurts:

- **Controls** — `Toggle`, `Slider`, `Divider`. (`Button` exists.)
- **Transitions** — animating a view *appearing* or *disappearing*. Value
  animation exists; transitions need removed nodes to outlive their removal,
  which touches the three reconcilers that drop nodes (`EitherView`, `ForEach`,
  `OptionalView`).
- **Overlays** — menus, dropdowns and tooltips need to draw above everything,
  which means appending to the draw list after the main tree walk.
- **Environment** — `Theme.current` and `FontStore.default` are globals. They
  should be environment defaults, not the only way to set a value.
- **Per-node invalidation** — a change re-runs the whole tree. Correct, but
  coarser than it needs to be.
- **Multi-window** — `LayoutHost`, `FocusManager` and `ViewInvalidation` all
  assume one window.
- **IME and BiDi** — Latin-only, deliberately. Fine for a PLC editor; it should
  be a stated scope rather than a surprise.
- **Block comments** — syntax highlighting is line-at-a-time, so constructs
  spanning lines cannot be expressed. That is where a rule list needs to become
  a stateful lexer.

## Notes

`docs/declarative-ui-plan.md` is the working plan and carries the reasoning
behind most of the decisions above, including several that were reversed and
why.
