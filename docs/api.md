# LavaUI API guide

This document describes the application-facing LavaUI API as it exists today.
LavaUI uses SwiftUI-shaped value descriptions, Yoga layout, retained view nodes,
and a Vulkan renderer. It is currently a Linux framework; some declarations are
compiled only when `CxxCanvas` is available.

```swift
import LavaUI

struct CounterView: View {
    @State private var count = 0

    var body: some View {
        VStack(padding: 12, alignment: .center) {
            Text("Count: \(count)", color: .accent)
            Button("Increment") { count += 1 }
        }
        .frame(width: .pct(100), height: .pct(100))
    }
}
```

## Application lifecycle

Open the native window once, load any application-owned resources, then enter
the event/render loop:

```swift
guard let editor = LavaApp.open(
    title: "My App", width: 1280, height: 800
) else {
    exit(1)
}

let logo = ImageStore.loadAsset(
    named: "logo.png", bundle: .module, into: editor
)

LavaApp.run(editor: editor) {
    RootView(logo: logo)
}
```

`LavaApp.open(title:assetsRoot:width:height:)` creates the engine window,
loads LavaUI's fonts, and installs the clipboard bridge. `assetsRoot` normally
does not need to be supplied. `LavaApp.run(editor:menu:onRawKey:makeRoot:)`
runs until the window closes. `onRawKey` sees key events before normal focus,
overlay, and content-scale handling; return `true` to consume an event.

The optional `menu` closure builds a `LavaMenu.MenuBar`. See
[native menus](native-menus.md) for its DSL and Linux backends.

## View descriptions

Every composite view conforms to `View` and returns another view description
from `body`:

```swift
struct StatusPanel: View {
    let connected: Bool

    var body: some View {
        HStack(padding: 8, alignment: .center) {
            Text(connected ? "Connected" : "Offline")
            Spacer()
            if connected {
                Text("live", color: .accent)
            }
        }
    }
}
```

`@ViewBuilder` supports multiple children, `if`, `if/else`, and optional
children. It deliberately does not support a plain `for` loop because index
identity is unstable. Use `ForEach` with an explicit stable key:

```swift
ForEach(tracks, id: \.id) { track in
    Text(track.title)
}
```

The `Identifiable` overload omits `id:`. `EmptyView` represents no content.
`dumpStructure()` prints a description of a view tree for diagnostics.

LavaUI reconciles descriptions into a retained node tree. A `body` is not a
render callback: it is recomputed only when observed data used by that body
changes. Layout and painting can then run without reconstructing the tree.

## State and bindings

### `@State`

Use `@State` for view-owned values that affect structure, layout, or ordinary
view properties. Its storage survives reconstruction of the view struct.

```swift
@State private var expanded = false

Toggle("Details", isOn: $expanded)
if expanded { DetailsView() }
```

### `@DrawState`

Use `@DrawState` for high-frequency, paint-only values captured by an already
mounted `Canvas` paint closure, such as a hover coordinate or drag boundary.
A write requests redraw only; it does not recompute `body` or layout.

```swift
@DrawState private var cursorX: Float?
```

Do not use it when the value changes text outside the paint closure, layout,
or view structure; those require `@State`.

### `Binding`

`Binding<Value>` is a two-way value reference. Obtain one with `$state`, build
one from closures, or bind a property of a reference model:

```swift
let binding = Binding(
    get: { model.query },
    set: { model.query = $0 }
)

let shorter = Binding(model, \.query)
```

For an `@Observable` reference model, `@Bindable` supplies SwiftUI-style
dynamic member projection:

```swift
@Bindable var session: Session
TextField(text: $session.query, placeholder: "Search")
```

Use a reference model for state shared with code outside the view tree, such
as an application menu.

## Layout

### Stacks

`HStack` lays children out horizontally and `VStack` vertically:

```swift
HStack(
    flexGrow: 1,
    width: .pct(100),
    height: .auto,
    padding: 8,
    alignment: .center,
    wraps: false,
    onClick: { select() },
    onHover: { inside in hovered = inside }
) {
    Text("Leading")
    Spacer()
    Text("Trailing")
}
```

`StackAlignment` controls the cross axis: `.start`, `.center`, `.end`, or
`.stretch`. `wraps: true` continues children onto another line when the main
axis fills. There is currently no stack `spacing` parameter; use padding on
children where spacing is required.

`Spacer(flexGrow:)` consumes remaining space. It is the idiomatic way to push
later content to the trailing or bottom edge.

### Dimensions and frames

`Dimension` accepts `.auto`, `.undefined`, `.point(Float)` / `.pt(Float)`, and
`.percent(Float)` / `.pct(Float)`. Percent values use percentages, so
`.pct(100)` fills the parent and `.pct(50)` uses half of it.

```swift
content.frame(
    width: .pt(320), height: .auto,
    minWidth: 160, minHeight: 40
)
```

`flexGrow(_:)` claims available main-axis space. `flexShrink(_:)` controls how
the view contracts when the container is too small.

Modifier order can affect layout. In particular, `.frame(...).padding(8)`
creates outer padding around the explicit frame, while
`.padding(8).frame(...)` applies the fixed frame to the padded box.

### Scrolling and lazy content

```swift
ScrollView(.vertical, showsIndicator: true) {
    LazyVStack(items, rowHeight: 36, spacing: 2) { item in
        Row(item: item)
    }
}
```

`ScrollView` supports `.vertical` and `.horizontal`. `LazyVStack` and
`LazyVGrid` virtualize fixed-size cells and must be placed in a vertical
`ScrollView`:

```swift
LazyVGrid(albums, cellWidth: 180, cellHeight: 250, spacing: 10) {
    AlbumCard(album: $0)
}
```

The grid determines the column count from available width. Lazy cells are
unmounted when they leave the viewport, so state that must survive scrolling
belongs in the model rather than inside a cell.

## Common modifiers

Modifiers apply to any `View`:

| Modifier | Effect |
|---|---|
| `.padding(Float)` | Inner spacing; may form an outer box when order requires it |
| `.background(Color)` | Box fill |
| `.hoverBackground(Color)` | Fill while hovered |
| `.cornerRadius(Float)` | Rounded box corners |
| `.frame(width:height:minWidth:minHeight:)` | Yoga dimensions and minimums |
| `.flexGrow(Float)` | Main-axis growth, default argument `1` |
| `.flexShrink(Float)` | Contraction priority |
| `.clipped()` | Scissor this view and its descendants to its layout box |
| `.blur(radius:)` | Blur this view's own rendered content |
| `.backdropBlur(radius:)` | Blur content already painted behind the view |
| `.theme(Theme)` | Override the theme for this subtree |
| `.font(UIFont)` | Override the font for this subtree |
| `.transition(Transition)` | Animate insertion/removal appearance |
| `.onDrop { urls in ... }` | Accept dropped files in this view's bounds |
| `.agentId(String)` | Give automation/agent tooling a stable identifier |

Paint-only modifier chains normally collapse onto one node. LavaUI adds a
wrapper only for fragments or when modifier order creates a real layout
boundary.

## Built-in views

### Text and controls

```swift
Text(
    "Artist",
    color: .primary,
    hoverFill: nil,
    hoverColor: .accent,
    cornerRadius: 4,
    lineLimit: 2,
    onClick: openArtist
)

Button("Save", isEnabled: canSave, action: save)
TextField(
    text: $query,
    placeholder: "Search",
    multiline: false,
    maxLines: 8,
    wraps: false,
    onSubmit: search
)
Toggle("Live parsing", isOn: $live)
Slider(value: $volume, in: 0...1, step: 0.01)
```

`Text.lineLimit(_:)` wraps within its resolved width and ellipsizes the last
visible line. Clickable `Text` receives the theme hover surface by default;
specifying `hoverColor` gives link-like text hover without a row fill.

`TextField` supports single- and multiline editing, selection, clipboard,
undo, search-related text infrastructure, and optional soft wrapping.
`ButtonStyle`, `ToggleStyle`, and `SliderStyle` expose the colors, geometry,
padding, and animation duration for their controls.

`Divider()` infers its axis from its parent stack; it can also be initialized
with `.horizontal` or `.vertical` and a `DividerStyle`.

`Expand(title:isExpanded:style:content:)` provides a disclosure section with
an animatable body.

### Images

Load an application resource once when possible:

```swift
let image = ImageStore.loadAsset(
    named: "cover.png", bundle: .module, into: editor
)

if let image {
    Image(image, width: .pt(160), height: .pt(160), contentMode: .fit)
}
```

For asynchronous/path-based artwork, keep the same leaf mounted:

```swift
Image(
    path: coverPath,
    width: .pt(160), height: .pt(160),
    placeholder: Environment.current.theme.inset,
    placeholderCornerRadius: 6,
    contentMode: .fill
)
.clipped()
```

`ImageContentMode` is `.stretch`, `.fit`, or `.fill`. Path images decode on
demand, are cached by `ImageStore`, and request redraw without rebuilding the
body. Definite point dimensions allow decoding near the displayed resolution.

### Editor and Markdown

`EditorView` is the full code/log editor:

```swift
@State private var source = ""
private let controller = EditorController()

EditorView(
    text: $source,
    rules: highlightRules,
    style: CodeStyle(),
    showLineNumbers: true,
    visibleLines: 16,
    search: TextSearch(),
    decorations: diagnostics,
    onDecorationTap: { diagnostic in inspect(diagnostic) },
    controller: controller
)

controller.reveal(line: 120) // one-based physical line; focuses and centers it
```

Highlighting rules and search types are re-exported from `LavaText`.
`EditorDecoration` adds severity, underline style, optional gutter icon,
color, and message to a character range.

`MarkdownView(markdown, style: MarkdownStyle(), font: nil)` renders styled
Markdown text. It handles Markdown as character styling in the native text
renderer rather than embedding a browser.

## Overlays

LavaUI has two overlay forms with different interaction semantics.

### Composed overlay

Use `overlay(alignment:inset:content:)` for an always-present badge, floating
button, or control. It takes no layout space and does not block interaction or
dismiss on outside click:

```swift
content.overlay(alignment: .bottomTrailing, inset: 16) {
    Button("Assistant") { showAssistant = true }
}
```

`OverlayAnchor` provides all nine combinations of top/center/bottom and
leading/center/trailing.

### Presented overlay

Use `overlay(isPresented:...)` for a popup, dropdown, menu, or modal surface.
It is emitted above the complete tree, escapes scroll clipping, receives input
first, and dismisses on an outside click:

```swift
searchField.overlay(
    isPresented: $showResults,
    alignment: .below,
    style: OverlayStyle(minWidth: 680)
) {
    SearchResults()
}
```

`.below` and `.above` automatically flip at the viewport edge. For a modal
plane or another custom frame, supply an `OverlayPlacement`:

```swift
root.overlay(
    isPresented: $showAssistant,
    placement: .viewport(inset: 24),
    style: OverlayStyle(backdropBlurRadius: 8)
) {
    AssistantView()
}
```

For arbitrary placement, initialize `OverlayPlacement` with a closure receiving
the anchor frame, viewport frame, and the overlay's ideal size, and return an
`OverlayFrame` in window coordinates.

## Custom drawing with `Canvas`

`Canvas` participates in Yoga layout but owns no child views. Its paint closure
receives an absolute `CanvasFrame` and a reused `DrawList`:

```swift
Canvas(
    label: "timeline",
    height: .pt(240),
    flexGrow: 1,
    onGesture: handleGesture,
    onWheel: handleWheel
) { draw, frame in
    draw.roundedRect(
        x: frame.x, y: frame.y, w: frame.w, h: frame.h,
        color: .background, radius: 6
    )
    draw.polyline(points, color: .accent)
}
```

`onGesture` receives `.began`, `.moved`, and `.ended` with local and window
coordinates. Pointer capture keeps delivering a drag after it leaves the
canvas. `onWheel` includes the local pointer position. `continuousRedraw: true`
requests animation frames while a live canvas needs them.

Application-facing `DrawList` primitives include:

- `rect`, `roundedRect`, `circle`, `line`, and `polyline`
- `polygon`, `ring`, and `pieSlice`
- `text` and `image`
- `pushClip` / `popClip`
- explicit backdrop/content blur scopes

Coordinates passed to `DrawList` are window coordinates. Prefer `polyline` for
large connected series: it emits one line-strip command and a contiguous
vertex range rather than one command per segment.

## Spatial UI with `Scene3D`

`Scene3D` is a Yoga leaf whose contents use a separate depth-tested graphics
pipeline. Normal LavaUI views before and after it retain their draw-list order,
and each scene clears depth only inside its own viewport.

```swift
@State private var hovered: Int?
let catalogLayout = CatalogLayout3D.focusedShelf()

Scene3D(
    camera: .perspective(
        position: [0, 0, 7], target: [0, 0, 0],
        fieldOfView: .degrees(42)
    ),
    height: .pt(320),
    flexGrow: 1,
    cameraControls: .orbit(
        minimumDistance: catalogLayout.recommendedMinimumCameraDistance(
            itemCount: albums.count, itemWidth: 1.25, itemHeight: 1.25
        ),
        maximumDistance: 14
    )
) {
    AmbientLight3D(intensity: 0.28)
    DirectionalLight3D(direction: [-0.35, -0.6, -1], intensity: 1.05)
    ForEach3D(Array(albums.enumerated()), id: \.element.id) { index, album in
        Box3D(
            id: album.id, width: 1.25, height: 1.25, depth: 0.08,
            color: .accent
        )
        .material3D(.albumCover(front: album.cover, edgeColor: .dim))
        .shadow3D(radius: 15, offsetX: 7, offsetY: 11, opacity: 0.3)
        .catalog3D(
            index: index, itemCount: albums.count,
            focusedIndex: hovered, layout: catalogLayout
        )
        .animation3D(.spring(response: 0.3, dampingFraction: 0.7))
        .onHover3D { inside in hovered = inside ? index : nil }
        .onTap3D { open(album) }
    }
}
.cornerRadius(8)
```

The initial predefined geometry is `Plane3D` and `Box3D`. `Material3D` supports
a color or a textured front surface; `.albumCover(front:edgeColor:)` puts a
cover texture on the front of a thin box and gives its remaining faces a
separate edge color. Atlas-backed `UIImage` UVs are handled automatically.
`AmbientLight3D` and `DirectionalLight3D` illuminate transformed face normals;
scenes without explicit lights receive a neutral default rig. Spatial modifiers
include `position`, `offset3D`, uniform/vector `scale3D`, axis-angle
`rotation3D`, `animation3D`, `onHover3D`, and `onTap3D`. Object identifiers
must be stable: retained transform animation and hit dispatch are keyed by id.

Use `.animation3D(.spring(response:dampingFraction:))` for responsive hover
motion. A shorter response reacts faster; a damping fraction below `1` adds
overshoot, `1` is critically damped, and values above `1` settle without
bouncing. `.smooth(duration:curve:)` remains available for time-based motion.

`CatalogLayout3D.focusedShelf()` provides a depth-aware album/poster layout.
Apply it with `.catalog3D(index:itemCount:focusedIndex:layout:)`; the focused
item lifts and scales while its neighbors spread, recede, and fan toward it.
`recommendedMinimumCameraDistance(...)` returns a conservative orbit radius
from the shelf and item dimensions, keeping the camera outside the catalog.

`.shadow3D(...)` projects the transformed card silhouette into a shared
offscreen mask and Gaussian-blurs it. Radius and offset are expressed in screen
pixels, so the shadow remains visually consistent while the cover moves in
depth. `Shadow3DStyle` can also be passed when the same configuration is shared
by many objects. This is a scene-local spatial UI effect, not a general mesh
shadow map.

`Camera3D.perspective` accepts position, target, field of view, and near/far
planes. Pointer picking tests the projected triangles and selects the nearest
depth, matching visible overlap. Transform interpolation lives on the retained
scene node, so animation frames request redraw without recomputing `body`.

Pass `cameraControls: .orbit(...)` to enable retained scene navigation. Drag
to orbit, Shift-drag to pan, and use the wheel or trackpad to zoom. Distance
and pitch limits, input sensitivity, inertia, and deceleration are configurable
through `CameraControls3D`; omit it for a fixed camera. A drag is distinguished
from a click on release, so moving the camera does not activate a 3D object.
`Scene3D` always emits a scissor matching its layout box, so projected objects
and blurred shadows cannot paint outside the scene viewport; `.clipped()` is
not required for this.

Physically based material parameters and imported meshes remain
future layers on the same scene command path.

## Theme, fonts, and animation

`Theme` contains semantic text colors, accent/selection colors, surfaces,
border and corner geometry, control padding, caret width, and focus-ring
configuration. Built-ins are `Theme.dark` and `Theme.light`; the process-wide
default is `Theme.current`.

Prefer semantic colors such as `.primary`, `.secondary`, `.accent`,
`.selected`, `.muted`, and `.dim`. `Color.opacity(_:)` replaces alpha and
`lightened(_:)` derives a lighter variant.

Use `.theme(customTheme)` and `.font(customFont)` for scoped overrides. Fonts
can be loaded with `UIFont(path:pixelSize:)`; `FontStore` owns the default,
symbol font, content scale, and shape caches.

`Transition.opacity`, `Transition.slide(dx:dy:)`, and custom `Transition`
values support fade/offset animation with `.linear`, `.easeOut`, or
`.easeInOut` curves.

## Files, settings, and diagnostics

`FileDialog.openFile`, `openFiles`, and `saveFile` provide native-style file
selection. The current backend is Linux `zenity`; calls block until selection
or cancellation and return no result when unavailable or cancelled.

`AppSettings.configure(appName:)` selects the application settings file.
`string`, `int`, `bool`, `double`, and generic `Codable` getters/setters are
available, along with `remove`, `removeAll`, and `keys`.

For profiling and automation:

- `PerfCounters` exposes frame/work counters used by LavaBench.
- `WidgetProfiler` records per-widget emission time.
- `.agentId(_:)`, `AgentServer`, and `AgentHost` expose the UI to the Lava agent
  protocol; see [agent integration](agent.md).

These are lower-level facilities; ordinary application views do not need them.

## Current API boundaries

The API intentionally resembles SwiftUI, but it is not source-compatible with
SwiftUI. Notable current boundaries are:

- Linux is the working platform today.
- Stack main-axis justification and a native `spacing` argument are not yet
  present; use `Spacer` and child padding.
- Lazy containers require fixed cell/row heights.
- `FileDialog` currently depends on `zenity`.
- A plain `for` loop is unavailable in `@ViewBuilder`; identity requires
  `ForEach`.
- `Canvas` drawing uses absolute window coordinates.

Known bugs and planned framework work are tracked separately in
[issues.md](issues.md) and the product-specific gap documents.
