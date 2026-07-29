# Declarative UI: migration to a retained view graph

Plan for evolving the editor chrome from an immediate-mode `UINode` tree into a
SwiftUI-shaped framework with persistent node identity, view-local state, and
incremental layout.

This is a **migration** plan, not a greenfield one. It assumes the existing
`canvas` engine, `CxxCanvas`/`CYoga` interop, and `canvas::Font`.

---

## Where we are today

Phases 0–4 and 3.5 are done. The legacy `UINode`/`uiTree_` path this plan
started from has been deleted end to end.

| Piece | Today | File |
|---|---|---|
| Description | `View` protocol + `@ViewBuilder`, parameter packs (no gyb) | `Sources/LavaUI/` |
| Identity | Retained `ViewNode` tree, `NodeID`, structural reconciliation | `LavaUI/LayoutNode.swift` |
| Layout | Yoga, Swift side via `CYoga`; fragments add no flex boxes | same |
| Text layout | `Font::measure`/`wrapLines` + `TextLayoutCache` | `LavaUI/Font.swift` |
| Text shaping | **Swift only** — shaped runs cached per line on `UIFont` | same |
| Rendering | One ordered `QuadRenderer` pass; rounded-box SDF + glyph atlas | `canvas/src/render/quad_renderer.cpp` |
| Glyph atlas | `TextRenderer` as glyph cache; keyed `(fontId, glyphId)`, grows | `canvas/src/render/text_renderer.cpp` |
| Hit test | **Swift**, reverse-z over laid-out node frames | `LavaUI/LayoutNode.swift` |
| Events | Raw `pollInputEvent`; handlers live on the node | `LavaUI/Editor.swift` |
| Reactivity | `@State` + `Observation`; `ViewInvalidation` flag drives the frame | `LavaUI/State.swift` |

The original premise — "nothing persists between commits" — is now fully
addressed. The library is `LavaUI`; `HelloWorld` is just the app on top of it.

Deleted along the way: `GeometryRenderer`, `LineRenderer`, `Mesh3DRenderer`,
`Camera`, the 3D shaders, the retained shape/label/line stores, the
`uiBegin`/`uiText`/`uiEnd`/`uiCommit` builder, `shell::WidgetTree`, and
`TextRenderer`'s entire draw path.

---

## The framing decision: be frame-driven

The reference implementation (SwiftCrossUI) is *event-driven* — a state change
synchronously walks the graph, recomputes layout, and commits. That design forces
it to carry ~60 lines of semaphores and exponentially-smoothed throttling in
`Publisher.swift` purely to stop the main thread starving under rapid updates.

We have a swapchain and an existing frame loop. State changes should only ever
**set dirty flags**; layout and draw happen once per frame:

```
loop:
  if let deadline = wakeDeadline { glfwWaitEventsTimeout(deadline - now) }
  else                           { glfwWaitEvents() }          // blocks, 0% CPU

  drainInputEvents()        // hit test → handlers → may set dirty
  tickAnimations()          // may set dirty, may set next wakeDeadline

  guard dirty else { continue }   // no acquire / submit / present

  if needsBodyRecompute { recomputeDirtyBodies() }              // Swift
  if needsLayout        { YGNodeCalculateLayout(root, w, h, LTR) }
  emitDrawList()                                                // → POD buffer
  acquire → record → submit → present                           // C++, FIFO-paced
  dirty = false
```

Every coalescing and re-entrancy problem that throttling machinery exists to
solve disappears. Decide this first — it is very hard to retrofit.

It also replaces the manual `lastSelected != selectedBlockId` comparison in the
run loop with an automatic dirty flag.

### Four things this loop gets right that a naive version doesn't

**Block, don't spin or poll.** The current `Thread.sleep(0.016)` wakes 60×/sec
forever and adds up to 16ms of input latency. `glfwWaitEvents()` sleeps in the
kernel until there is something to do. From a background thread, wake it with
`flag = true; glfwPostEmptyEvent()` — never by polling an atomic.

**Idle means no present at all.** There is no cheap "re-present the last frame":
`vkAcquireNextImageKHR` may hand back a *different, older* image with stale
contents, so showing correct pixels would mean rendering anyway. The gate
therefore belongs *before* acquire. The window keeps displaying the last
presented image — that is the compositor's job.

**A wakeup deadline, not an `isAnimating` bool.** A bool breaks on concurrent
animations (whichever ends first clears it) and over-wakes badly: caret blink is
a 2Hz effect that a bool would run at 60fps. Store the earliest instant anything
needs to wake:

```swift
var wakeDeadline: ContinuousClock.Instant?   // nil = sleep indefinitely
```

A spring registers ~16ms out, caret blink 500ms, a delayed tooltip 800ms. One
mechanism, composes cleanly, no over-waking. With `VK_PRESENT_MODE_FIFO_KHR`
present already blocks to vsync, so animation pacing is free — don't add a manual
sleep on top or you get judder.

**Single-threaded.** Yoga is not thread-safe per tree and nodes are `@MainActor`,
so a plain `Bool` suffices for dirty tracking. A separate render thread would buy
little and cost double-buffered draw-list arenas, thread-confinement discipline,
and cross-thread ARC traffic.

The flags cascade — body → layout → emit → present — and are not one flag. A
window resize needs layout but not body recompute; an opacity animation needs
emit but not layout. One bool is fine at current scale; just don't let a fade
re-run Yoga once animations exist.

---

## Decision 1: the retention boundary — SETTLED

**Swift owns Yoga** (via `CYoga`); C++ has dropped Yoga entirely. **Swift owns
hit testing**, against its own laid-out node frames. C++ receives **draw commands
only** and knows nothing about widgets.

`ARCHITECTURE.md` still describes the old split (Yoga + widget tree + hit test in
C++) and is stale. It should be rewritten or deleted — nothing it documents
exists any more.

That does *not* make C++ stateless. The rule:

> **Retain in C++ what is expensive to build and keyed by _content_.
> Re-emit from Swift everything keyed by _position or structure_.**

| Stays in C++ | Moves to Swift |
|---|---|
| Glyph atlas (rasterized bitmaps → texture) | `LabelShape` map + `nextLabelId` |
| Vulkan pipelines, buffers, descriptor sets, swapchain | `addRect`/`addRoundedRect`/`addCircle`/`addLine` stores |
| `Font` shaping (FreeType + HarfBuzz) | `setProjectTree` / `setProperties` / `setWorkspaceLayout` |
| ST editor text model (for now — see Phase 7) | The whole `uiBegin`/`uiText`/`uiEnd`/`uiCommit` path ✅ deleted |

The node tree *is* the retained scene. Nothing needs a second copy of it.

---

## Decision 2: two gaps in the `Font` API

Both change `shape()`, so fix them in one pass.

### 2a — `measure` needs an available width

`canvas::Font` already gets the important parts right — `const std::string&`
(a non-const ref would import as `inout` and force a mutable copy), and
`TextMetrics` carries `ascent`/`descent` for baseline alignment.

The gap is wrapping. Yoga calls a measure function with an available width and a
`YGMeasureMode`, and for `YGMeasureModeAtMost` the text must line-break at that
width. The current signature can only ever measure a single line:

```cpp
// current
TextMetrics measure(const std::string &text) const;

// needed
TextMetrics measure(const std::string &text, float availWidth, int mode) const;
```

`mode` maps directly:

| `YGMeasureMode` | Meaning |
|---|---|
| `Undefined` | Shape one line, return ideal width |
| `AtMost` | Line-break at `availWidth`, return wrapped size |
| `Exactly` | Width fixed; return resulting height |

Multi-line also means `shape()` needs to return per-line runs (or take the same
width/mode) so drawn output matches what was measured — the invariant `font.hpp`
is explicitly built to protect.

### 2b — `PositionedGlyph` needs a cluster ✅ DONE

```cpp
// current — cannot support a text cursor
struct PositionedGlyph { uint32_t glyphId; float x, y; };

// needed
struct PositionedGlyph { uint32_t glyphId; float x, y; uint32_t cluster; };
```

`cluster` is HarfBuzz's `hb_glyph_info_t.cluster` — the byte offset in the source
string that each glyph originated from. It is the *only* way to map a click x to a
cursor position, or a cursor position to a caret x. Ligatures and combining marks
make the naive "one glyph per character" assumption wrong immediately.

Without this, Phase 7 cannot start. With it, both mappings are a walk over the
run (`ShapedRun.caretX(for:)` / `ShapedRun.index(atX:)`).

Shipped with an `advance` field alongside it: the caret midpoint test needs
per-glyph advance, and it is *not* `next.x - x`, because `x` also carries
GPOS/kerning offsets.

---

## Phases

### Phase 0 — Spikes ✅ DONE

Three things can fail in ways that change the design. Half a day each, throwaway.

**Results:** `docs/phase0-results.md` · run with `swift run Phase0Spikes`
(`Sources/Phase0Spikes/`, delete after Phase 1).

| Spike | Verdict |
|-------|---------|
| **0a** Parameter packs / `TupleView` + pack children → `[LayoutChild]` | **PASS** — no gyb |
| **0b** `YGMeasureFunc` from Swift + `MarkDirty` re-measure | **PASS** |
| **0c** `Font::measure` / `TextMetrics` under `-std=c++23` | **PASS** |

Carry-forwards (not blockers): text leaves must not be stretch-aligned if
intrinsic width matters; AtMost may exceed `availWidth` on unbreakable words;
`CYoga` SPM target is headers-only (symbols today come from `libcanvas`).

**0a. Parameter packs for `TupleView`.** Modern Swift may remove the need for
generated `TupleView1…N`:

```swift
struct TupleView<each C: View>: View { var content: (repeat each C) }
extension ViewBuilder {
    static func buildBlock<each C: View>(_ c: repeat each C) -> TupleView<repeat each C>
}
```

Prove the *children* side too — `(repeat AnyViewNode<each C>)` stored in a class,
and building a `[LayoutChild]` array by pack iteration. If diagnostics are
unworkable, fall back to gyb codegen and set the generator up immediately rather
than hand-writing two variants.

**0b. Yoga measure func from Swift.** The fiddliest interop:

```swift
let fn: YGMeasureFunc = { node, w, wMode, h, hMode in
    let leaf = Unmanaged<TextLeaf>.fromOpaque(YGNodeGetContext(node)!)
        .takeUnretainedValue()
    return leaf.measure(width: w, mode: wMode)
}
YGNodeSetContext(node, Unmanaged.passUnretained(leaf).toOpaque())
YGNodeSetMeasureFunc(node, fn)
```

The closure must capture nothing to convert to a C function pointer. Verify that
`YGNodeMarkDirty` + recalculate actually re-invokes it — note it **asserts on
nodes without a measure function**, so it applies only to text leaves.

**0c. `Font::measure` across the boundary with the new signature.** Confirm
`TextMetrics` still imports cleanly as a Swift value type once the extra params
are added, under `-std=c++23`.

---

### Phase 1 — `View` protocol and builder ✅ DONE

Replace the `UINode` enum with a real protocol layer. No nodes, no rendering yet.

**Sources:** `Sources/HelloWorld/View/` · dump runs once at HelloWorld startup
(`Phase1Dump`). Legacy `UI.swift` still drives the live chrome.

- `View` with `associatedtype Body: View`, `var body: Body`
- `@ViewBuilder`: pack `buildBlock`, `buildEither`, `buildOptional`,
  `buildExpression` — **no `buildArray`** (use `ForEach(_:id:)`)
- `EmptyView`, `TupleView<each>`, `EitherView`, `OptionalView`, `ForEach`
- `PrimitiveView` + `PrimitiveViewBuilder.buildNodeGroup()` (**no default** —
  compile-time safety for layout)
- `Color` (RGBA), `Dimension` (undefined / auto / point)
- SCUI trick: defaults *forward to `body`*; primitives never touch `body`
- `EditorChrome: View` rewrites chrome description

**Done when:** the existing `rebuildChrome()` body can be rewritten as `View`
structs and you can recursively `dump()` the resulting type structure. `if/else`
produces `EitherView`; two statements produce `TupleView`.

---

### Phase 2 — Retained node tree + Yoga mirror ✅ DONE

**Sources:** `LayoutNode.swift`, `ViewGraph.mount` / `reconcile`, `LayoutHost`.
Startup: `Phase2Dump` checks **root identity** (`mounts=1`, `reconciles≥1`, same
`NodeID`) and layout frames (no fragment boxes).

- **Retained nodes**: `setRoot` reconciles in place; Yoga nodes live with ARC
  (`deinit { YGNodeFree }`), not freeTree rebuild
- **Fragments** (no Yoga box — splice into parent): `TupleView`, `EitherView`,
  `OptionalView`, `ForEach`, `CompositeNode`
- **Yoga boxes**: `StackNode` (H/V only), `LeafNode` (Text / Spacer / DiagramHost)
- **ForEach**: keyed recon by `id` key path
- **EitherView**: reuses branch node when case stays; remounts on flip
- `YGNodeCalculateLayout(w,h)` only — does not clobber root style

**Still open:** Font-backed measure (Phase 4), per-node dirty flags for the
frame loop, `@State` storage on nodes (Phase 5).

The load-bearing phase. Node identity is **structural** — types encode tree
shape, so there is no general diffing.

```swift
@MainActor final class ViewNode<V: View> {
    let id: NodeID              // stable for the node's lifetime
    var view: V
    let yoga: YGNodeRef         // created once, never swapped
    var children: any NodeChildren
    var needsBodyRecompute = true
}
```

The `yoga` handle lives as long as the node. A node that switches between two
children owns a *container* `YGNode` and swaps what's inside it — never returns
a child's node directly, or it could never switch back.

Only two places need real reconciliation:

- `EitherView` case flip → `YGNodeRemoveAllChildren` + `YGNodeInsertChild`
- `ForEach` keyed diff → port SwiftCrossUI's `ForEach.swift:97-187` roughly as-is;
  it's the only genuine reconciliation in that codebase and it's correct

Modifiers become Yoga style setters (`.padding` → `YGNodeStyleSetPadding`,
`.frame` → `SetWidth`/`SetHeight`, `.flexGrow` → `SetFlexGrow`). Style setters
auto-dirty, so invalidation is free.

> **Migration hazard — widget ids.** Today `UI.beginCommit()` resets `nextId = 1`
> and ids are assigned in *build order*. That only works because the whole tree is
> rebuilt and swapped atomically. With retained nodes, an id must name a stable
> node, not a build-order position — otherwise handlers start firing on the wrong
> widget the moment the tree shape changes.
>
> This disappears entirely once hit testing moves to Swift (Phase 6) and handlers
> live on the node. **Consider pulling Phase 6 forward to here** rather than
> building a `[NodeID: ViewNode]` bridge you're going to delete.

**Done when:** nested stacks with fixed-size leaves produce correct absolute
frames from `YGNodeCalculateLayout`, printed to stderr. No rendering.

---

### Phase 3 — Draw list ✅ DONE (v1)

**Live path:** `HelloWorldApp` → `LayoutHost` + `DrawList.emitTree` +
`Editor.submitDrawList` — no legacy `UI`/`uiBegin` chrome. FBD diagram emits
into the same list (window coords + host origin). Raw `pollInputEvent` + Swift
hit-test drives `Text.onClick`.

**C++:** `canvas::DrawCommand` (32B POD), `submitDrawList`, `pollInputEvent`,
`setDiagramViewport`. Repaint executes the list (rects/circles/lines/text).

**Still open:** glyph-level text (Phase 4), full clip stack in Vulkan, engine
API collapse (delete retained-shape methods), frame-idle gate (no spin sleep).

**Define the command struct in the C++ header and import it.** Swift's struct
layout isn't C-ABI-guaranteed even when frozen; let C++ stay authoritative.

```c
typedef struct {
    uint32_t kind;       // rect, roundedRect, textRun, image, pushClip, popClip
    float    x, y, w, h;
    uint32_t color;      // RGBA8
    uint64_t param;      // shaped-run handle / texture id
    float    aux;        // corner radius, etc.
} DrawCommand;           // keep at 32B, fixed stride
```

Emission is one depth-first walk in z-order over committed frames, appending into
a **reused** `UnsafeMutableBufferPointer<DrawCommand>`. Never allocate per frame;
grow the arena and reuse it. One pointer + count crosses the boundary per frame.

**Pre-order DFS, not BFS.** Paint order *is* z-order: a node emits its own
background, then recurses into children in sequence, so children paint over
parents and siblings paint in order. BFS would emit all of depth 1 then all of
depth 2, putting a deep node's background over a shallow sibling's content. The
clip stack also only nests under DFS — `pushClip` on entry, `popClip` on exit;
BFS has no coherent "exit".

Three things keep the walk from being fully trivial:

- **Accumulated offset.** `YGNodeLayoutGetLeft/Top` are parent-relative; carry a
  running origin down and add it. (Opacity and transforms, if added later,
  compose down the same way.)
- **Clip push/pop** around scroll views and overflow-hidden containers. Stack
  depth must balance or scissor state leaks into siblings.
- **Culling.** Skip a subtree whose frame doesn't intersect the viewport. ~5
  lines, and it's what keeps a long project tree or a large FBD diagram cheap.
  Do it from the start.

### "If we re-emit every frame, what is retained?"

The draw list is the only immediate part of the system, and it's the cheapest
layer. What's retained is the node tree and everything hanging off it:

| Layer | Re-run every frame? |
|---|---|
| `body` (user view code) | **No** — only nodes whose observed state changed |
| Layout | **No** — Yoga reuses cached measurements for clean subtrees |
| Text shaping | **No** — cached per node |
| Draw list emission | Yes — a dumb walk over already-computed values |
| GPU submit | Only when dirty |

The first row is the headline. ImGui re-executes the *entire* UI function every
frame because that function is the only representation of the UI. Here, user code
runs only for the handful of nodes whose observed properties changed — frequently
none.

Persisting on the tree: `@State` storage, scroll offsets, focus, text editing
state, in-flight animations, shaped runs, Yoga's measure cache, and the
observation subscriptions recording which node depends on which property. That
last one is what makes skipping work possible at all; ImGui has nowhere to put it.

Identity differs too: ImGui hashes the **label string** into an ID-keyed side
table (which is why two buttons labelled "OK" share state until you `PushID`).
Ours is **structural**, derived from the tree's type, so it can't collide, and
state lives on the node rather than beside it.

Retained data structure, declarative API on top — the same shape as SwiftUI,
Flutter, and React. All of them look immediate at the call site and are retained
underneath.

**Text emission.** A `textRun` command can't carry the string — that would
reshape every frame. `Font::shape()` already returns `std::vector<PositionedGlyph>`,
so: Swift caches the shaped run per text node (Phase 4) and emits **one command
per glyph** carrying `{glyphId, x, y, color}`; C++ resolves `glyphId` → atlas UV,
rasterizing on miss. The atlas stays in C++; no run registry is needed. If command
count ever hurts, add opaque run handles then — not now.

**Frame gating.** Emit on dirty, re-present otherwise (a desktop editor is mostly
idle). Keep emission itself a dumb full walk — gate the walk, don't diff it.

### Why not partial redraw

Full-scene redraw is close to free at this scale: a few thousand batched quads at
1280×800 is sub-millisecond on any desktop GPU. ImGui rebuilds *and* redraws its
entire UI every frame at thousands of FPS. The CPU-side emission walk costs more
than the rasterization.

Three caches are easy to conflate. They are independent and separately gateable:

| Layer | Cached by | Invalidated when |
|---|---|---|
| View tree + layout | Swift node graph | state change / Yoga dirty |
| Draw list buffer | Swift, reused arena | tree or layout changed |
| Framebuffer pixels | swapchain | draw list changed |

Gate the third at **frame** granularity, not region: if nothing is dirty, don't
record, submit, or present. That is 0% GPU while idle — the entire practical
benefit of damage tracking, in ~15 lines.

Region-level damage is deceptively expensive in Vulkan. `vkCmdSetScissor` is the
easy part; the hard part is that with 2–3 swapchain images in rotation, redrawing
only the damaged region into image N leaves images N−1 and N−2 stale elsewhere.
Damage must be tracked *per swapchain image* and accumulated since that image was
last presented — Vulkan has no buffer-age query, so that bookkeeping is yours.
`LOAD_OP_CLEAR` also becomes `LOAD_OP_LOAD`. `VK_KHR_incremental_present` does not
help: it hints the compositor at present time, it doesn't let you skip rendering.

If a single frame's redraw ever does become too slow, the next step is **layer
caching** (render static panels to an offscreen image once, composite them), not
damage rectangles.

**Clipping is still required** — scroll views and overflow-hidden containers need
it. Swift computes clip rects (it owns layout) and emits `pushClip`/`popClip`;
C++ maintains a scissor stack and applies `vkCmdSetScissor`. Hit testing walks the
same stack Swift-side. Build it for scroll views, not for partial redraw.

### Engine API collapse

This phase is where the C++ surface shrinks. Roughly forty methods become:

```
openWindow / close / isOpen / setWindowFrame
submitDrawList(const DrawCommand*, size_t)
pollInputEvent(InputEvent&)          // raw — see Phase 6
Font::{measure, shape, rasterize, lineHeight}
repaint / readPixels
```

Deleted: `addRect`, `updateRect`, `addRoundedRect`, `addCircle`, `removeShape`,
`clearShapes`, `addLine`, `removeLine`, `clearLines`, `addLabel`, `removeLabel`,
`clearLabels`, `setProjectTree`, `setProperties`, the tree/properties builder
methods, `setWorkspaceLayout`, `setWorkspaceColumns`, and the entire
`uiReset`/`uiBegin`/`uiText`/`uiEnd`/`uiCommit`/`uiPollEvent` path.

Retained for now: `addTextWidget` and the highlight-rule API (see Phase 7).

`FBDRenderer` migrates onto the same draw list — the diagram is just more
commands, and re-emitting a few thousand per frame is not a real cost.

**Done when:** the current three-panel chrome renders as colored rects, positioned
by Yoga, driven from `View` structs, with the retained-shape API deleted.

---

### Phase 3.5 — Unified quad renderer ✅ DONE

**The problem.** `application.cpp` draws with three accumulate-then-flush
renderers at fixed z-levels:

```cpp
lineRenderer.draw(commandBuffer);
renderer.draw(commandBuffer, imageIndex);   // geometry
textRenderer.draw(commandBuffer, ...);
```

Paint order is therefore **lines < geometry < text, globally**, and the draw
list's index ordering is discarded at replay. It looks right today only by
coincidence: panel fills are geometry and labels are text, so text lands on top.

What breaks: a caret is a rect, so it can never draw over its own glyphs
(Phase 7); a dropdown, tooltip, or modal can never cover a label; an FBD wire
can never cross over a block.

**Nothing on the Swift side changes.** `DrawCommand` and emission are already
correct — index order *is* paint order. This is purely a replay-side rewrite.

#### Not the depth buffer

Deriving depth from command index fails here: a UI is almost entirely
alpha-blended (antialiased glyph coverage, rounded-corner SDFs, translucent
panels), and transparent fragments writing depth punch holes behind them. You'd
still need an ordered transparent pass.

#### One rounded-box SDF covers four kinds

| Kind | Rounded box params |
|---|---|
| Rect | `radius = 0` |
| RoundedRect | `radius = aux` |
| Circle | `halfSize = (r, r)`, `radius = r` |
| Line | rotate to segment-local space → `halfSize = (len/2, w/2)`, `radius = w/2` |

A stroked line with round caps *is* a capsule, and a capsule is a rounded box in
the segment's local frame — so `Line` needs no shader special case. The CPU emits
a rotated quad carrying local coordinates.

SDF also gives free antialiasing, which `GeometryRenderer` does not have:

```glsl
float d  = sdRoundBox(vLocal, vHalfSize, vRadius);
float aa = fwidth(d);
float cov = 1.0 - smoothstep(-aa, aa, d);
```

#### Text stays a texture sample

Do **not** go to MSDF to unify further. FreeType R8 coverage is sharper at UI
point sizes, and MSDF generation is a pipeline of its own. One `flat uint kind`
branch in the fragment shader is enough, and batches cluster into runs of glyphs
or runs of shapes, so warp divergence is negligible.

#### White texel in the glyph atlas

If solid shapes and glyphs use different descriptor sets, every text↔shape
transition breaks a batch. Reserve one texel of the glyph atlas as opaque white
and have solid quads sample it: **one descriptor set for everything**, leaving
scissor as the only batch break.

```
for cmd in drawList:            // index order preserved
    if pushClip / popClip: flushBatch(); setScissor(...)
    else:                  appendQuad(cmd)
flushBatch()
```

Draw calls per frame = clip regions + 1. A typical frame is one.

#### Vertex format

```c
struct QuadVertex {
    float    pos[2];       // screen pixels
    float    local[2];     // SDF space, or atlas UV when glyph
    float    halfSize[2];
    float    radius;
    uint32_t color;        // RGBA8, fetched as R8G8B8A8_UNORM → vec4
    uint32_t kind;         // 0 = sdf, 1 = glyph
};
```

Line rotation is baked CPU-side (four corners in screen space plus matching local
coords), keeping the vertex shader a pass-through. Projection is a `vec2 viewport`
push constant — pixels → NDC in the vertex shader, no UBO or extra descriptor.

#### Scope

**Delete:** `GeometryRenderer`, `LineRenderer`, and `TextRenderer`'s
pipeline/draw path.

**Keep:** `TextRenderer`'s glyph atlas — rasterization, packing, upload. Phase 4
already reduces it to that, which is exactly "retain in C++ what is expensive and
keyed by content".

**Boundary:** ImGui has its own pipeline and is a hard batch break. Draw it after
the unified pass as a top overlay; it stays above everything, which is fine while
it's chrome being deleted anyway.

#### Staging

1. `QuadRenderer` behind a runtime flag, old path still default.
2. Port kinds in order: `Rect` → `RoundedRect` → `Circle` → `Line` → `Text`.
3. Compare against the old path with `readPixels`, so "at parity" is an assertion.
4. Flip the default, then delete `GeometryRenderer`/`LineRenderer`.

Two details that bite otherwise: offset positions by half a pixel for crisp 1px
lines and rect edges, and grow the vertex buffer rather than reallocating per
frame — same arena discipline as the Swift side.

**Done when:** chrome, diagram, and text all render through one pipeline in draw
list order, a rect emitted after text covers it, and clip regions scissor.

---

### Phase 4 — Text ✅ DONE

- `UIFont` wraps `canvas::Font`; `FontStore.bootstrap` at startup (16px, same as
  C++ TextRenderer)
- `Text` leaves install `YGMeasureFunc` → `Font::measure(text, avail, mode)`
- **`TextLayoutCache`** keyed on `(text, fontId, widthQ, mode)`; hit rate dumped
  at startup (`Phase4Dump`)
- `Font::prepareWrap` / `wrapLineAt` for multi-line emit matching measure breaks
- `YGNodeMarkDirty` when text changes; draw emits one command per wrapped line

**Done when:** a paragraph wraps correctly inside a resizing panel, and cache hit
rate is >90% on a static frame.

---

### Phase 5 — State and reactivity ✅ DONE

Landed as designed: `Mirror`-based transplant for ownership, `Observation` for
change tracking. `EditorChrome` now owns selection and click count as `@State`,
and the run loop no longer mirrors or diffs view state — `dirty` tracks only
what Observation cannot see (window size, font scale).

`ViewInvalidation` is a bare flag rather than a per-node dirty set: a mutation
marks it, the frame loop consumes it. That keeps the design frame-driven — a
state change never synchronously walks the graph. It also means invalidation is
currently whole-tree; per-node granularity is a later optimisation, not a
correctness gap, because `setRoot` reconciles from the root every frame anyway.

Verified: `Phase5StateDump` (storage survives rebuild, mutation invalidates)
plus a driven three-click UI test, which matters because
`withObservationTracking` fires `onChange` exactly once — the second and third
clicks are what prove re-registration works.

Two *separate* concerns that SwiftCrossUI conflates into one mechanism.

**Ownership — state must outlive the view struct.** When a parent rebuilds its
body, the child's `@State` is brand new; the old storage must be transplanted.
SwiftCrossUI does this with cached byte offsets after reimplementing
`_forEachField` from the stdlib. We don't need that. Because `State` holds a
*class* box, read-only `Mirror` suffices — the mutation goes *through* the
reference:

```swift
for (old, new) in zip(Mirror(reflecting: oldView).children,
                      Mirror(reflecting: newView).children) {
    if let o = old.value as? any StateProperty,
       let n = new.value as? any StateProperty {
        n.adoptStorage(from: o)   // n.box is shared with newView's field
    }
}
```

Correct on day one, slow. When it shows in a profile, replace with a `@View`
macro synthesizing a typed `_adoptState(from:)` — compile-time, no reflection.
**Don't build the macro first.**

**Change tracking — use `Observation`, not a hand-rolled publisher.** Make
`@State`'s storage observable so `@State` and user model objects flow through one
mechanism:

```swift
@Observable final class StateStorage<Value> { var value: Value }
```

Then wrap body computation:

```swift
withObservationTracking {
    newBody = view.body
} onChange: { [weak self] in
    Task { @MainActor in self?.markNeedsBodyRecompute() }
}
```

This gives per-property dependency tracking across *any* object the body reads —
including `FBDModel` types, if they become `@Observable`. It deletes the manual
`lastSelected`/`lastClicks` diffing in the run loop entirely.

Two real gotchas:

- **`onChange` fires *before* the write lands** (willSet semantics). Never read
  new values inside it — the frame-driven model handles this naturally.
- **It fires exactly once.** Re-registration happens implicitly on body
  recompute; skip a recompute and you've silently unsubscribed.

**Done when:** clicking a block in the tree updates the properties panel with no
manual state comparison anywhere in `HelloWorldApp`.

---

### Phase 6 — Input routing ✅ MOSTLY DONE (landed early, out of order)

Hit testing moves to Swift, against the node frames Yoga computed. C++ no longer
knows what a widget is, so it **cannot resolve widget ids** — this is a signature
change, not a relocation:

```cpp
// before: C++ hit-tests and reports which widget was hit
bool uiPollEvent(int &outWidgetId, int &outKind);

// after: C++ reports raw input; Swift resolves it
bool pollInputEvent(InputEvent &out);   // mouse move/down/up, key, scroll, resize
```

Swift side:

- Reverse-z walk over committed frames, respecting the clip stack
- Pointer capture — a drag started in a node keeps receiving events outside it
- Focus ring + tab order, keyboard routing to the focused node
- Event → state mutation → dirty flag → next frame. **Never** synchronous
  relayout inside a handler.

This also retires the `handlers[id]` registry in `UI`: handlers live on the node
(`node.onClick`), reached directly by the hit test. The Phase 2 id hazard
dissolves rather than needing a fix — there is no id to keep stable.

**Landed early**, because Phase 2 needed it: leaving `handlers[id]` in place
while nodes became persistent would have meant building a `[NodeID: ViewNode]`
bridge only to delete it. Done: raw `pollInputEvent`, reverse-z hit walk,
`node.onClick`, dirty-flag-on-mutation. Still open: pointer capture, focus ring
and tab order, keyboard routing — all of which Phase 7 needs anyway.

---

### Phase 7 — Text editing ⬅ IN PROGRESS

The largest single chunk of work in the whole plan, and the only place where
dropping ImGui costs more than it looks. Budget accordingly.

**Unblocked**: `PositionedGlyph` carries `cluster` + `advance` (Decision 2b).

Landed so far — step 1's foundation:

- `LavaText` — a separate, dependency-free target holding `TextEditingState`.
  Splitting it out makes "testable headlessly" a property of the build graph
  rather than of discipline; it also sidestepped SwiftPM refusing to propagate
  C++ interop settings into a test target.
- `ShapedRun` (in `LavaUI`, needs the shaper) — `caretX(for:)` and
  `index(atX:)`, both via HarfBuzz clusters, snapped to grapheme boundaries.
- 18 unit tests covering grapheme movement, selection ordering, word
  boundaries, and multi-byte insertion.

Step 1 now also has: `FocusManager` (focus keyed by `NodeID`, since the view
struct is rebuilt while the node persists), a `TextField` primitive view,
caret + selection + focus-ring rendering, clipboard via GLFW, and a `Text`
input event carrying committed characters (key codes are physical and say
nothing about layout or dead keys).

Caret blink decision, per the warning above: blink only while focused, solid
for 500ms after any edit so it never blinks mid-typing, and the frame loop
redraws only when the blink *phase flips* — 2 frames/sec while focused, zero
when not. That keeps idle gating intact.

Also landed: drag-select via `PointerCapture` (a drag that leaves the field
must keep extending, which the hit test alone cannot do), and double-click
word selection via `ClickCounter`. `MouseMove` is now emitted by the engine
but **only while button 1 is held** — free hover motion would flood the
unbounded input queue for nothing.

Verified interactively: click focuses and places the caret, typing reaches the
buffer and re-filters a `ForEach` through the binding, Ctrl+A selects all,
drag-select highlights a sub-range, and double-click selects a word.

Remaining for step 1: confirming the clipboard round-trip.

**Correction to the note below**: Foundation's
`enumerateSubstrings(options: .byWords)` is *unavailable* in
swift-corelibs-foundation, so word boundaries are hand-rolled from Character
classification (letters, digits, underscore). That is also the right unit for a
code editor, which is where this ends up.

#### Swift does the hard part for you

A cursor is not a byte offset and not a character index. `String.Index` is
grapheme-cluster-correct by default: `index(after:)` steps over an emoji ZWJ
sequence, a combining accent, or a regional-indicator pair as a single unit —
exactly what an arrow key should do. `enumerateSubstrings(options: .byWords)`
gives word boundaries for double-click and Ctrl+arrow. This is materially *less*
work than the C++ equivalent.

#### Separate pure logic from rendering

The highest-leverage structural decision here. Editing state knows nothing about
glyphs or the GPU:

```swift
struct TextEditingState {
    var text: String
    var anchor: String.Index      // selection origin
    var focus: String.Index       // moving end / caret
    mutating func moveLeft(extending: Bool)
    mutating func deleteBackward()
    mutating func insert(_ s: String)
}
```

Everything except hit-testing and caret-x is then testable headlessly. This is
precisely the code where a few hundred unit tests cost an afternoon and save a
fortnight — grapheme edge cases, selection normalization, delete-with-selection,
word jumps at boundaries.

Only two operations need the shaper, and both reduce to cluster lookup:

```swift
func index(atX: Float) -> String.Index      // click → cursor
func caretX(for: String.Index) -> Float     // cursor → pixel
```

#### Caret blink vs. frame gating

A blinking caret dirties the frame at 2Hz forever while focused, which defeats
the idle gating from Phase 3. Pick one deliberately:

- accept the 2Hz wakeup (harmless on desktop)
- don't blink (VS Code ships a solid-caret option; many editors default to it)
- blink only after an idle timeout, so it's still while typing

Any is fine. Drifting into the first by accident is not.

#### Ladder — keep ImGui until the top

The trap is replacing the ST editor first because it's the visible one. Invert:

1. **Single-line, Latin, no IME.** Property-panel edits. Selection, caret,
   click-to-place, shift-select, clipboard via `glfwGet`/`SetClipboardString`.
   Covers most of the UI; a few days.
2. **Multi-line.** Soft wrap reusing Phase 4's wrapping. Vertical caret movement
   needs "desired x" memory across lines — a classic bug source.
3. **Undo/redo.** Structure edits as operations *from the start*; painful to
   retrofit once the string is mutated in a dozen places.
4. **Port the ST editor.** Only once 1–3 handle everything it needs, including
   syntax-highlight ranges.

`addTextWidget` and the highlight-rule API stay untouched through 1–3. That is
what makes this a migration rather than a rewrite.

#### Decide explicitly, don't drift

- **IME** — CJK, plus dead keys / compose on Linux. Check what GLFW actually
  provides for preedit; historically thin. "No IME" may be a defensible permanent
  scope for a PLC editor — but state it.
- **BiDi** — needs FriBidi or ICU to segment runs by direction *before* HarfBuzz
  shapes them. Same call: Latin-only is fine if chosen, not if assumed.

---

### Phase 8 — Windows and scenes

Genuinely the thinnest layer, which is why it's last. One window = one root node
+ one Yoga root + one swapchain. `SwiftCrossUI`'s multi-pass window sizing exists
to negotiate with a native window manager that owns sizing; we don't have that.
Use `YGNodeCalculateLayout` with `YGUndefined` when intrinsic size is needed,
otherwise lay out at the swapchain extent.

---

## Ordering rationale

Phases 1–4 give a static UI that renders. Phase 5 is what makes it a *framework*.
The temptation is to do state early because it's the interesting part — resist it.
State is only correct if node identity is correct, and node identity is exactly
what Phases 2–3 shake out.

**Phase 7 dominates the schedule.** Text editing is larger than Phases 1–3
combined, and it is the only phase where the ImGui fallback has to survive
alongside the new path for a while. Everything before it should be sized with that
in mind.

## Open questions

- Does `FBDModel` become `@Observable`, or stay a value-type graph with explicit
  invalidation? Affects how much Phase 5 buys.
- IME and BiDi scope (Phase 7) — "Latin-only, no IME" is defensible for a PLC
  editor, but it should be a stated decision, not a drift.
- ImGui: still used for the menu bar. Does that survive, or become views too?
- Platform: `Package.swift` declares `.macOS(.v13)` while `CxxCanvas`/`CYoga` are
  `.when(platforms: [.linux])`. Is macOS a real target or vestigial?
- `ARCHITECTURE.md` is stale (describes Yoga + widget tree + hit test in C++).
  Rewrite or delete.
