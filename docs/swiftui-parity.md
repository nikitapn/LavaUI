# LavaUI ↔ SwiftUI parity

LavaUI is deliberately SwiftUI-shaped (`View`, `@ViewBuilder`, `@State`, stacks,
modifiers) but is **not** source-compatible. This document tracks what is still
missing or only partially present, ordered so the next work is obvious.

It is an API gap list, not a bug list. Incorrect behaviour goes in
[issues.md](issues.md). Product-specific needs live in their own gap docs.
The broader framework assessment is [lavaui-assessment.md](lavaui-assessment.md).

**Status legend**

| Tag | Meaning |
|---|---|
| absent | Not in the public API |
| partial | Exists under a different shape, or only for some types |
| different | Present by design, intentionally not SwiftUI-compatible |

---

## Guiding principles

1. **Match the call site when cheap.** `.padding(.horizontal, 8)` is worth
   looking like SwiftUI; a full PreferenceKey system is not free.
2. **Keep Lava strengths.** Yoga flex, `@DrawState`, dual overlays, Canvas
   gestures, Scene3D, client/compositor mode — do not delete these to chase
   source compatibility.
3. **One layer at a time.** Prefer finishing a small cluster (edge padding +
   frame completeness) over scattering half-done modifiers.
4. **Document intentional divergence** in [api.md](api.md) when we ship a
   different shape on purpose.

---

## Tier 0 — Easy wins

Small surface area, Yoga/modifier machinery already exists, immediate payoff
for every app. **Start here.**

### 0.1 Edge-aware padding — **done** (2026-08-08)

| | |
|---|---|
| Status | **done** |
| API | `Edge`, `EdgeInsets` in `EdgeInsets.swift`; three `.padding` overloads |
| Tests | `Tests/LavaUITests/PaddingTests.swift` |

```swift
content.padding(8)                                              // all edges
content.padding(.horizontal, 12)
content.padding(.top, 4)
content.padding(EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4))
```

`ViewStyle` / `YogaBoxNode` store `EdgeInsets`; Yoga gets per-edge
`YGNodeStyleSetPadding` with LTR mapping (leading→left, trailing→right).
Stack/button/overlay inits still take uniform `Float` and convert with
`.all(...)`. Padding after another modifier still forces an outer box.

---

### 0.2 View opacity

| | |
|---|---|
| Status | absent (only `Color.opacity`) |
| Today | Transition alpha exists internally; no public `.opacity` |

**Proposed:** `.opacity(Float) -> …` on `View`, stored on `ViewStyle`, applied
at emit (multiply subtree alpha). Composes with transition alpha.

Cheap once emit has a place to multiply; no layout impact.

---

### 0.3 Offset (2D)

| | |
|---|---|
| Status | absent |
| Today | Transition has temporary translation; no permanent `.offset` |

**Proposed:** `.offset(x:y:)` — paint + hit-test shift without affecting Yoga
layout (SwiftUI semantics). Layout-affecting position can wait.

---

### 0.4 Disabled / hidden as modifiers

| | |
|---|---|
| Status | partial — `isEnabled:` on Button/Toggle/Slider only |
| Proposed | `.disabled(Bool)`, `.hidden()` or `.opacity(0)` + hit-test skip |

Tree-wide disable should block clicks on descendants. Hidden should remove from
hit testing and ideally from layout (`hidden` that still occupies space vs a
true collapse — pick SwiftUI’s “occupies space, not hit-testable, not drawn”
unless we also want a collapse helper).

---

### 0.5 Lifecycle hooks

| | |
|---|---|
| Status | absent |
| Proposed | `.onAppear { }`, `.onDisappear { }`, `.onChange(of:initial:_:)` |

Appear/disappear fire from mount/unmount (and transition leave finish).
`onChange` needs a retained previous value on the node or a small wrapper.
High value for apps; moderate plumbing.

---

### 0.6 Fuller `.frame`

| | |
|---|---|
| Status | partial |
| Today | `width`, `height`, `minWidth`, `minHeight` — no max, no ideal, no alignment |

**Proposed (minimal):**

```swift
func frame(
    width: Dimension? = nil, height: Dimension? = nil,
    minWidth: Float? = nil, maxWidth: Float? = nil,
    minHeight: Float? = nil, maxHeight: Float? = nil
) -> …
```

Yoga already has min/max width/height. Alignment inside a larger frame (SwiftUI
`alignment:`) needs a wrapper box + cross-axis align — do after max sizes if
needed separately.

---

### 0.7 Edge padding on stacks (optional follow-on)

Once `EdgeInsets` exists, consider:

```swift
HStack(padding: EdgeInsets.horizontal(8), …) { … }
```

or keep stack padding uniform. Modifier-only is enough for Tier 0.

---

## Tier 1 — Everyday app surface

Needed by most non-trivial UIs once Tier 0 is done.

### Layout

| Gap | Status | Notes |
|---|---|---|
| **`ZStack`** | absent | Alignment + layered children; apps fake it with overlays |
| **Main-axis justification** | absent | Documented; `Spacer` only. Yoga `justify-content` |
| **`GeometryReader`** | absent | Or a narrower `onSizeChange` if full reader is heavy |
| **`.border` / stroke** | absent | Expand fakes borders with nested fills |
| **`.background` with a view** | partial | Color only |
| **`.clipShape` / `.mask`** | partial | `.clipped()` = axis-aligned scissor |
| **`.shadow` (2D)** | absent | `shadow3D` only |
| **`.foregroundColor` cascading** | partial | Init args on Text/controls; no environment text color |
| **`.fixedSize` / `.aspectRatio` / `.layoutPriority`** | absent | |

### Controls & text

| Gap | Status | Notes |
|---|---|---|
| **`Button` label builder** | partial | `Button("Title")` only |
| **`Text` composition** | partial | Single `String`; no `Text+Text`, attributes |
| **`Label`**, **`Link`**, **`SecureField`** | absent | |
| **`Picker`** | partial | `ComboBox` is the menu style: closed field + anchored dropdown, mouse-driven, no arrow keys |
| **`Stepper`**, **`ProgressView`** | absent | Build ad hoc when needed |
| **`List` / `Form` / `Section`** | absent | Recipes with stacks may suffice medium-term |

### Interaction

| Gap | Status | Notes |
|---|---|---|
| **Gesture system** | partial | Canvas `onGesture`; stacks `onClick`/`onHover`; no `DragGesture` / `.gesture` |
| **`.onTapGesture` / `.onHover` general** | partial | Not on arbitrary views |
| **Focus traversal + `@FocusState`** | partial | Focus for fields exists; no Tab order, no binding |
| **`.keyboardShortcut`**, help/tooltip | absent | |

### Animation

| Gap | Status | Notes |
|---|---|---|
| **`withAnimation` / `.animation(_:value:)`** | absent | Node-local `Animated<T>` only |
| **Richer transitions** | partial | opacity + slide only |
| **`matchedGeometryEffect`** | absent | |

### Environment & wrappers

| Gap | Status | Notes |
|---|---|---|
| **`@Environment` + custom keys** | partial | Only `theme` + `font` via `.theme`/`.font` |
| **`@AppStorage`** | different | `AppSettings` exists; not a property wrapper |
| **`.id(_:)` identity override** | absent | |

### Presentation

| Gap | Status | Notes |
|---|---|---|
| **`.sheet` / alert / confirmation** | partial | `overlay(isPresented:)` covers many cases |
| **`.contextMenu`** | absent | |
| **`.searchable`** | absent | |

---

## Tier 2 — Structure & scale

| Gap | Status | Notes |
|---|---|---|
| **`NavigationStack` / split / link** | absent | Or a thin app-level router first |
| **`TabView`** | absent | |
| **`LazyHStack` / `LazyHGrid`** | absent | Vertical-only lazy today |
| **Variable-height virtualization** | absent | Fixed cell stride only (by design so far) |
| **Both-axis `ScrollView`** | partial | One axis per scroll view |
| **`ScrollViewReader` / programmatic scroll** | absent | |
| **`Group` / `AnyView` / `EquatableView`** | absent | |
| **Custom `Layout` protocol** | absent | Yoga is the only engine |

---

## Tier 3 — Platform & infrastructure

Tracked more fully in the assessment; listed here so parity work doesn’t forget
them.

| Gap | Status | Cost |
|---|---|---|
| **Accessibility** (AT-SPI, roles, labels) | absent | High; constrains the node model — don’t defer forever |
| **IME / complex text** | absent | TextField is Latin-oriented |
| **HiDPI auto scale** | partial | Manual `FontStore.scale` zoom |
| **Text selection outside `EditorView`** | absent | |
| **Declarative `App` / `Scene` / `WindowGroup`** | different | `LavaApp.open` + `run` is intentional for now |
| **Multi-window polish** | partial | `WindowScope` exists; not full Scene multi-window |

---

## Already present (do not re-implement)

Use as the baseline when reading the tables above.

**Core:** `View`, `@ViewBuilder` (no bare `for`), `EmptyView`, `ForEach`,
retained identity, Observation.

**State:** `@State`, `Binding`, `@Bindable`, `@DrawState` (Lava-only).

**Layout:** `HStack`, `VStack`, `Spacer`, `ScrollView`, `LazyVStack`,
`LazyVGrid`, `Dimension` (auto / pt / pct), flex grow/shrink.

**Controls:** `Text`, `Button`, `TextField`, `Toggle`, `Slider`, `Divider`,
`Expand`, `Image`, `Canvas`, `EditorView`, `MarkdownView`.

**Modifiers:** padding (uniform), background color, hoverBackground,
cornerRadius, frame (partial), flexGrow/Shrink, blur, backdropBlur, clipped,
theme, font, transition, onDrop, overlay (composed + presented), agentId.

**Other:** menus, FileDialog, Scene3D, client/compositor frame path, agent
server.

---

## Intentional divergences (not gaps)

| LavaUI | Why |
|---|---|
| No `buildArray` / plain `for` in builders | Index identity is unstable; force `ForEach` |
| Stack params include `flexGrow`, `width`, `wraps`, `onClick` | Yoga + less modifier noise for common cases |
| `ButtonStyle` as a color/metrics struct | Not a `makeBody` protocol — enough for themed controls |
| `@DrawState` | Paint-only invalidation without body recompute |
| Dual overlay APIs | Composed badge vs modal/presented popup |
| `LavaApp.open` / `run` | Frame-driven Vulkan loop, client mode, menus |
| Fixed-height lazy cells | Exact offset→index; no scrollbar jitter |

---

## Suggested implementation order

Concrete sequence for the next few PRs:

| # | Work | Depends on |
|---|---|---|
| 1 | ~~`Edge` + `EdgeInsets` + edge padding~~ | **done** |
| 2 | **`.opacity` + `.offset`** | Emit alpha / hit-test offset |
| 3 | **`.frame` max sizes** | Yoga min/max already |
| 4 | **`.disabled` / `.hidden`** | Hit-test + emit flags |
| 5 | **`.onAppear` / `.onDisappear` / `.onChange`** | Mount lifecycle |
| 6 | **`ZStack`** | Alignment enum reuse |
| 7 | **Stack main-axis justification** | Yoga justify-content |
| 8 | General `.onTapGesture` / `.onHover` | Hit-test hooks |
| 9 | `withAnimation` bridge into `Animated<T>` | Animation driver |
| 10 | Focus traversal | FocusManager |

After that, pick by product pressure (navigation, gestures, a11y, lazy
horizontal).

---

## When closing a gap

1. Implement against the proposed API in this doc (or update the proposal first
   if reality disagrees).
2. Add a short example to [api.md](api.md).
3. Mark the row here **done** with a one-line note (and date if useful).
4. Prefer a unit or layout test where the behaviour is structural (padding
   edges, frame max, ZStack order).

---

## Changelog

| Date | Note |
|---|---|
| 2026-08-08 | Initial inventory from LavaUI sources + api.md + assessment |
| 2026-08-08 | Tier 0.1 edge-aware padding shipped (`Edge` / `EdgeInsets` / overloads) |
