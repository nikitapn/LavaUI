# TraceLoom: LavaUI framework gaps

This file records framework limitations encountered while building TraceLoom. The product does not work around these by reaching into LavaUI internals.

## 1. Canvas pointer events do not include coordinates or drag phases — RESOLVED

`Canvas` exposes `onTap: (() -> Void)?`. A timeline needs node-local pointer coordinates and at least down/move/up phases to support a synchronized inspection cursor, drag-to-zoom, and range selection. Pointer capture exists internally, but an app-owned canvas cannot use it through public `Canvas` API.

Suggested framework shape: a typed canvas gesture event carrying local and window coordinates, button/modifiers, phase, and a supported pointer-capture lifecycle. Scroll events with local coordinates are also needed for wheel zoom.

TraceLoom impact: charts render on a unified timeline, but cursor inspection and direct manipulation are intentionally not implemented.

Fixed: `Canvas` gained `onGesture: ((CanvasGesture) -> Void)?` (`.began`/`.moved`/`.ended`, local + window coordinates, modifiers from the press) built on the existing internal `PointerCapture`, and `onWheel: ((dx, dy, localX, localY) -> Void)?` built on `ScrollRouter` plus a new `PointerState` (window-space pointer position, since a wheel notch carries none of its own) and a `LeafNode.lastCanvasFrame` cache. Mouse-button events now carry real GLFW modifiers end to end (`InputEvent.mods`, threaded through `hitTestClick`/`onClickLocal`); previously only left-button down/up existed and modifiers were discarded entirely. TraceLoom's unified timeline now has a synchronized inspection cursor built on `onGesture`; drag-to-zoom/range-select are left to the app, the API no longer blocks them.

## 2. No native file-open or drop surface

The old browser tool used a file input. LavaUI currently exposes clipboard plumbing for editors but no file picker and no drag-and-drop/file-drop view event.

Suggested framework shape: a platform file dialog service plus file-drop events on views. The dialog should return URLs and leave reading/decoding to the app.

TraceLoom impact: log input is pasted or typed into the built-in editor.

## 3. Editor highlighting cannot carry state between lines

`SyntaxHighlighter` applies regular-expression rules independently per line. A richer rule language eventually needs multi-line strings or comments, and possibly lexer state for embedded regular expressions.

Suggested framework shape: an incremental stateful lexer protocol whose state output for line N keys the cached highlighting of line N+1. Keep the existing rule list as the simple adapter.

TraceLoom impact: the current pipe-delimited rule DSL is deliberately line-oriented, so its useful syntax highlighting works within the existing API.

## 4. Editor validation markers are not expressible

Parser diagnostics can be shown below the editor, but `EditorView` has no public API for line diagnostics, gutter markers, underlines, or hover messages.

Suggested framework shape: editor decorations keyed by source range, with gutter icon/color, underline style, severity, and tooltip text.

TraceLoom impact: diagnostics identify the rule or log line in a separate status panel.

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
