# LavaUI issue list

Open framework bugs discovered while building and exercising LavaUI products.
Keep product-specific feature gaps in their product gap documents; this list is
for behavior that is incorrect or surprising across applications.

## 1. Focused caret keeps scheduling repaints while the window is minimized

**Status:** Open
**Area:** frame scheduling / window visibility / text input

### Observed

When a text field or editor retains focus and the window is minimized, caret
blinking continues to wake the main loop and request redraws. A minimized LavaUI
window therefore does not become fully idle.

### Expected

Caret animation should be suspended while the window is not visible. The window
should neither schedule caret wake deadlines nor submit caret-only frames while
minimized. On restoration, caret phase can be resynchronized and the window
redrawn once.

### Likely location

`LavaApp.run` already gates `AnimationDriver.tick()` with
`editor.isWindowVisible`, but the focused-caret block is outside that gate. It
still calls `CaretBlink.phaseChanged()` and `FrameScheduler.requestWake(...)`
whenever `FocusManager.focusedID` is non-nil.

### Acceptance criteria

- A minimized window with a focused editor produces no periodic caret frames or
  caret wakeups.
- Restoring it shows a valid caret without requiring new keyboard or pointer
  input.
- Normal visible-window caret blinking is unchanged.

## 2. Interactive descendants prevent wheel scrolling of an ancestor

**Status:** Open
**Area:** hit testing / wheel-event routing / `ScrollView`

### Observed

When the pointer is over a button inside a scrollable container, wheel input no
longer scrolls the container. Other interactive descendants are likely affected
for the same reason. Moving the pointer onto an inert part of the scroll content
makes wheel scrolling work again.

### Expected

Wheel input should reach the nearest scroll-capable node at or above the hit
node. A button may remain the hover/click target without swallowing wheel events
that it does not handle itself.

### Likely location

The scroll path resolves one node using `LayoutHost.hitTestHover` and passes only
that `NodeID` to `ScrollRouter.deliver`. `ScrollRouter` checks for a handler on
that exact node and does not walk or bubble through its ancestors. Consequently,
a topmost interactive child masks the enclosing `ScrollView`.

### Acceptance criteria

- Wheel input over a button, text field, canvas, or other interactive child
  scrolls the nearest ancestor `ScrollView` when the child has no applicable
  wheel handler.
- A child with its own wheel behavior can consume the event deliberately.
- Nested scroll views use a defined policy, preferably nearest eligible
  ancestor first with bubbling when it cannot scroll farther.
- Hover and click targeting remain unchanged.
