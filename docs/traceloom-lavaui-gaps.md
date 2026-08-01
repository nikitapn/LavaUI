# TraceLoom: LavaUI framework gaps

This file records framework limitations encountered while building TraceLoom. The product does not work around these by reaching into LavaUI internals.

## 1. Canvas pointer events do not include coordinates or drag phases — RESOLVED

`Canvas` exposes `onTap: (() -> Void)?`. A timeline needs node-local pointer coordinates and at least down/move/up phases to support a synchronized inspection cursor, drag-to-zoom, and range selection. Pointer capture exists internally, but an app-owned canvas cannot use it through public `Canvas` API.

Suggested framework shape: a typed canvas gesture event carrying local and window coordinates, button/modifiers, phase, and a supported pointer-capture lifecycle. Scroll events with local coordinates are also needed for wheel zoom.

TraceLoom impact: charts render on a unified timeline, but cursor inspection and direct manipulation are intentionally not implemented.

Fixed: `Canvas` gained `onGesture: ((CanvasGesture) -> Void)?` (`.began`/`.moved`/`.ended`, local + window coordinates, modifiers from the press) built on the existing internal `PointerCapture`, and `onWheel: ((dx, dy, localX, localY) -> Void)?` built on `ScrollRouter` plus a new `PointerState` (window-space pointer position, since a wheel notch carries none of its own) and a `LeafNode.lastCanvasFrame` cache. Mouse-button events now carry real GLFW modifiers end to end (`InputEvent.mods`, threaded through `hitTestClick`/`onClickLocal`); previously only left-button down/up existed and modifiers were discarded entirely. TraceLoom's unified timeline now has a synchronized inspection cursor built on `onGesture`; drag-to-zoom/range-select are left to the app, the API no longer blocks them.

## 2. No native file-open or drop surface — RESOLVED (Linux)

The old browser tool used a file input. LavaUI currently exposes clipboard plumbing for editors but no file picker and no drag-and-drop/file-drop view event.

Suggested framework shape: a platform file dialog service plus file-drop events on views. The dialog should return URLs and leave reading/decoding to the app.

TraceLoom impact: log input is pasted or typed into the built-in editor.

Fixed, Linux only:

- **`FileDialog`** (`Sources/LavaUI/FileDialog.swift`) — `openFile`/`openFiles`/`saveFile`, backed by `zenity` (GTK's file chooser) as a subprocess rather than linking GTK into a GLFW/Vulkan app that has no GTK event loop to host a real widget in. Blocks the calling thread until the user picks or cancels, like any native modal — call between frames, not from a paint closure. Returns `nil`/`[]` uniformly for "cancelled", "zenity not installed", and "not on Linux" — callers shouldn't need to tell those apart.
- **File drop** — `glfwSetDropCallback` wired in `application.cpp`, a new `InputEventKind::FileDrop` (cursor position + path count; the paths themselves are pulled by index via `Engine::pendingDroppedFile`, the same "fetch the payload while handling this event" pattern already used elsewhere, since a fixed-size `InputEvent` struct can't hold a variable string list). `Editor.droppedFiles()` surfaces them to Swift. `View.onDrop(perform:)` registers a handler through a new `DropRouter` (mirrors `ScrollRouter`'s exact shape), resolved via the same `hitTestHover` walk hover uses — extended to recognize a drop-registered box as a valid target even with no visual hover feedback of its own, since that registration is the only signal it has.

TraceLoom's log editor now has a "Load file…" button (`FileDialog.openFile`) and `.onDrop` on the same editor, both loading straight into the bound `log` text.

Verified live: the file dialog end to end, including driving the actual `zenity` window with `xdotool` (open it, type a path, confirm) and watching the app parse the loaded file. OS drag-and-drop was not: GLFW's XDND implementation itself is exercised by every app that uses it and wasn't re-verified here, but synthesizing a real X11 drag gesture from this environment to exercise *this* code's consumption path (the `FileDrop` event → `Editor.droppedFiles()` → `DropRouter` → `.onDrop`) wasn't practical — that path is confirmed by clean compilation and design review, following `ScrollRouter`'s already-tested shape, not by a live drop.

Not done: macOS/Windows backends (`NSOpenPanel` / `IFileDialog`) — this codebase only builds and runs on Linux today, so there was nothing to target.

## 3. Editor highlighting cannot carry state between lines — RESOLVED

`SyntaxHighlighter` applies regular-expression rules independently per line. A richer rule language eventually needs multi-line strings or comments, and possibly lexer state for embedded regular expressions.

Suggested framework shape: an incremental stateful lexer protocol whose state output for line N keys the cached highlighting of line N+1. Keep the existing rule list as the simple adapter.

TraceLoom impact: the current pipe-delimited rule DSL is deliberately line-oriented, so its useful syntax highlighting works within the existing API.

Fixed: `StatefulLexer` (`LavaText/Highlighting.swift`) — `associatedtype State: Hashable`, `highlight(_:state:) -> (spans:, nextState:)`. `SyntaxHighlighter` now either wraps a `[HighlightRule]` list (unchanged, `isStateful == false`) or a type-erased `StatefulLexer`; `SyntaxHighlighter.Cache` re-lexes incrementally — a common unchanged prefix is skipped outright, and re-lexing past an edit stops the moment a line's recomputed start-state and text both match what was cached there before (everything downstream is provably unaffected). `DrawList.emitEditor` drives the cache once per emit and reads per-row spans from it when `isStateful`.

No TraceLoom consumer: its rule DSL stays deliberately line-oriented (per the impact note above), so there's nothing in the product itself that needs cross-line state. Verified with unit tests in `LavaTextTests/StatefulLexerTests.swift` instead — a `/* */` block-comment lexer spanning lines, and an instrumented lexer asserting the cache actually skips unaffected lines (an edit mid-file re-lexes exactly one line when nothing downstream depends on it) rather than just checking the output is correct.

## 4. Editor validation markers are not expressible — PARTIALLY RESOLVED

Parser diagnostics can be shown below the editor, but `EditorView` has no public API for line diagnostics, gutter markers, underlines, or hover messages.

Suggested framework shape: editor decorations keyed by source range, with gutter icon/color, underline style, severity, and tooltip text.

TraceLoom impact: diagnostics identify the rule or log line in a separate status panel.

Fixed: `EditorView` gained `decorations: [EditorDecoration]` (character range, `DiagnosticSeverity` with default color/gutter glyph, `DecorationUnderline` straight/wavy/none, message) and `onDecorationTap: ((EditorDecoration) -> Void)?`. TraceLoom's rule/log editors now underline the exact line a diagnostic points at with a gutter marker, tap-through to the message.

Not done: **hover**, specifically. Nothing in the input pipeline feeds a leaf a continuous pointer position outside an active drag (`PointerCapture`) or a discrete click (`onClickLocal`) — `HoverState` only reports enter/leave, not a moving position. `onDecorationTap` (click the gutter icon) is the interaction this shipped with instead; a real hover tooltip needs a continuous-position hook generalizing what `Canvas.onGesture`'s `.moved` phase already proves is possible, scoped to non-dragging movement too.

## 5. No app lifecycle abstraction — RESOLVED

Creating a second LavaUI executable currently requires duplicating the complete window, frame, input, invalidation, font, clipboard, and agent-server loop from `HelloWorldApp`.

Suggested framework shape: a small public application host that accepts a window configuration and root-view factory while retaining hooks for app-level raw key handling.

TraceLoom impact: the package exposes `TraceLoom` as a new executable product backed by the existing executable target, avoiding a second copy of the loop.

Fixed: the loop now lives in `LavaUI.LavaApp` — `open(title:assetsRoot:width:height:)` (window + font bootstrap + clipboard) and `run(editor:onRawKey:makeRoot:)` (the full input/invalidation/render/agent-server loop, generic over `some View`), with `onRawKey` as the app-level raw-key hook. Split in two rather than one call because asset loading an app owns (TraceLoom has none; `DemoExample`'s brand image) has to happen once against an opened `Editor`, before `run`'s hot path — `LavaApp.resolveAssetsRoot(_:)` is exposed so a caller's own loading agrees with what `open` used internally.

This also undid a workaround from `TraceLoom`'s original landing: both executable products had pointed at the *same* target/`@main`, so `DemoExample` and `TraceLoom` could never run at the same time and `DemoExample` was unreachable dead code. `TraceLoomApp` is now its own target (`Sources/TraceLoomApp/`, ~20 lines) alongside `HelloWorld`'s own (~25 lines); both call `LavaApp` and both run independently again.

## 6. Proportional dimensions are missing — RESOLVED

`Dimension` exposes only `undefined`, `auto`, and fixed points. A desktop split workspace needs a proportional panel width (for example 38/62) while still respecting minimum sizes.

Suggested framework shape: percentage dimensions backed by Yoga's percent width/height APIs, or a fraction/flex-basis abstraction with min/max constraints.

TraceLoom impact: the rule/log pane is fixed at 440 points rather than scaling with the window.

Fixed: `Dimension.percent(Float)` (`.pct(_:)`), backed by `YGNodeStyleSetWidthPercent`/`HeightPercent`. `StackNode`'s side-column panel fill now also keys off `.percent`, not just `.point`. TraceLoom's rule/log pane uses `width: .percent(38)`; existing `minWidth`/`minHeight` still apply underneath it unchanged.

## 7. Canvas gestures do not expose canvas geometry — RESOLVED

`CanvasGesture.localX/localY` identify the pointer relative to the canvas, but the event does not include the canvas width/height or the `CanvasFrame` used by `paint`. TraceLoom can draw a drag selection because `paint` has the frame, but on `.ended` it cannot convert the selected boundary into a time value: that conversion needs `(localX - plotLeft) / (canvasWidth - plotLeft - plotRight)`.

Caching the last paint frame in app-owned mutable state would couple event correctness to a prior paint and mutate data from a rendering closure, so TraceLoom intentionally does not use that workaround.

Suggested framework shape: add `canvasWidth` and `canvasHeight` to `CanvasGesture`, or include the full current `CanvasFrame`. Normalized local coordinates would also solve the mapping, though the full frame is more generally useful.

TraceLoom impact: click-hold-drag highlights the selected interval and its boundaries, but button-up cannot commit the interval as the new timeline domain until this geometry is available.

Fixed: `CanvasGesture` now carries `frame: CanvasFrame`, the current absolute
geometry also passed to `Canvas.paint`. Captured move/up events derive their
local coordinates from that current frame rather than the origin cached when
the press began, so the values remain coherent if layout changes during a
gesture. TraceLoom maps the two local boundaries through the plot rectangle on
`.ended`, commits them to `zoomStart`/`zoomEnd`, and ignores movements below four
pixels as inspection clicks rather than creating a near-zero domain.

## 8. Agent automation cannot inject a drag — RESOLVED

The agent server exposes `move` and an atomic `click` that injects press and release together. It cannot hold a mouse button while sending one or more moves, so captured gestures such as timeline range selection cannot be tested through the LavaUI MCP/control plane.

Suggested framework shape: expose separate `pointer_down` and `pointer_up` methods, or a `drag` method accepting start/end and optionally intermediate points. Separate phases are more general and match the engine's existing `injectPointerButton` API.

TraceLoom impact: the redesigned layout and canvas can be inspected live, but the range-selection gesture currently requires manual testing.

Fixed: the agent protocol, CLI, and MCP surface now expose `pointer_down` and
`pointer_up` independently. Both accept coordinates or the same
`sid`/`label`/`id`/`query` targeting as `click`; each moves to the requested
position before changing the button so injected button coordinates and
`PointerCapture`'s last position agree. Arbitrarily many existing `move` calls
can run between the phases, exercising the real capture path rather than a
special synthetic-drag implementation.

Verified live against TraceLoom with `pointer_down` at `(300, 450)`, moves to
`(600, 450)` and `(900, 450)`, then `pointer_up`. The timeline committed
`19:16:16.821 — 19:16:22.017 · zoomed`, confirming both the automation phases
and the canvas-frame mapping end to end.

## 9. A view cannot place non-modal content over its own bounds — RESOLVED

LavaUI's `overlay(isPresented:alignment:)` is currently a popup/menu primitive:
it detaches a subtree, places it above or below an anchor, gives it input
priority, and dismisses it when the user clicks outside. There is no SwiftUI-like
composition overlay that keeps normal interaction underneath and aligns content
to a parent corner (`.bottomTrailing`, for example).

TraceLoom wants its AI-assistant launcher to float over the bottom-right corner
of the rules editor without consuming a layout row. Using a trailing `HStack`
places it correctly but still changes layout; using the popup API for an
always-present button would make the whole window behave like a modal menu and
swallow outside clicks. TraceLoom intentionally uses the small layout row until
the framework can express the real design.

Suggested framework shape: a compositional `overlay(alignment:)` whose content
is measured and painted above the base view, does not contribute to the base
view's Yoga size, and participates in ordinary hit testing without imposing
popup dismissal semantics. Corner/edge alignment plus an offset or inset is
enough for floating action buttons, badges, and in-canvas controls. Keep the
existing binding-based API as the modal popup/presentation variant.

Fixed: `overlay(alignment:inset:)` is the composition variant, distinct from the
existing `overlay(isPresented:)` popup, which keeps its detach/priority/dismiss
semantics unchanged.

It is an absolutely positioned Yoga child, so all four required behaviours come
from the layout engine rather than from special cases: an absolute child is out
of the flex flow (no layout contribution), it is declared second so emission
order paints it above the base, it is a real node with real geometry so hit
testing is ordinary, and Yoga edge insets keep it anchored across resizes.

Nine anchors — the corners, the edge midpoints, and the centre — plus an
`inset` that applies to pinned edges and is ignored on a centred axis.

One thing had to be found by measuring rather than reasoning: Yoga will not
centre an absolutely positioned node. Auto margins on one leave it pinned to
the leading edge. The fix is an absolute container pinned to all four edges of
the base, which exactly covers it, with the overlay placed inside by *ordinary*
`justifyContent`/`alignItems`. That container is a plain style box with no fill
or handlers, so despite covering the base it never claims a hit — verified by
hit-testing through it.

Verified with a probe carrying all nine anchors on a 200x120 box: an identical
bare box measured 200x120 too (no layout contribution), every anchor landed
within a pixel of its expected gaps, and the base stayed clickable underneath.

TraceLoom now floats its assistant launcher over the rules editor's
bottom-trailing corner with `inset: 8`, and the layout row it was using is
gone. Clicking the editor beneath the overlay still focuses it and places a
caret at the right character; the assistant *panel* stays a popup, because it
is on-demand and an outside click should dismiss it — which it still does.
