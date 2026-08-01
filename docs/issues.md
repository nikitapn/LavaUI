# LavaUI issue list

Open framework bugs discovered while building and exercising LavaUI products.
Keep product-specific feature gaps in their product gap documents; this list is
for behavior that is incorrect or surprising across applications.

## 1. Focused caret keeps scheduling repaints while the window is minimized

**Status:** Fixed
**Area:** frame scheduling / window visibility / text input

### Resolution

The focused-caret block in `LavaApp.run` moved inside the `isWindowVisible`
gate, so a minimized window neither calls `CaretBlink.phaseChanged()` nor
queues a caret wake. The loop also tracks the previous iteration's visibility;
on the invisible → visible edge it calls the new `CaretBlink.resync()` (adopts
the live phase, whose `lastPhase` went stale while suspended) and marks one
redraw, so the caret returns without keyboard or pointer input.

Verified against `HelloWorld` with a focused `TextField`: 8 caret redraws in 4s
while visible, 0 in 5s while iconified, and blinking resumes on restore.

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

**Status:** Fixed
**Area:** hit testing / wheel-event routing / `ScrollView`

### Resolution

Wheel routing now bubbles. `LayoutHost.hitTestScrollChain` is a new walk that
keeps the whole ancestor path under the pointer (innermost first) instead of
the single topmost hit, and `ScrollRouter.deliver` takes that chain and gives
the notch to the first handler willing to take it. `hitTestHover` and
`hitTestClick` are untouched, so hover and click targeting are unchanged.

Nested scroll containers use an eligibility predicate registered alongside the
handler: `ScrollNode` and `EditorView` report whether the notch would actually
move them, so one already pinned at its end passes the event out to the next
eligible ancestor. Omitting the predicate (as `Canvas(onWheel:)` does) means
consume unconditionally, which is how a widget with its own wheel behavior
keeps it.

Verified against `HelloWorld`: a wheel over the "Live lab" header and over a
focused `TextField`, both inside the center `ScrollView`, scroll the container
by exactly one notch step each; clicking the same header still toggles it.

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

## 3. Loading a large log file fails silently

**Status:** Open
**Area:** TraceLoom file ingestion / state update / parsing

### Observed

Selecting a larger log file (observed above approximately 10 MB) produces no
visible result. The existing log remains unchanged and nothing is written to
stderr, so the user cannot distinguish a rejected file, read failure, long parse,
or stalled UI update.

The approximate size boundary is an observation, not yet a confirmed framework
limit. Smaller files load through the same file dialog successfully.

### Expected

A selected readable text file should load regardless of this size. If loading or
parsing cannot complete, TraceLoom should retain the previous document and show
an actionable error instead of silently doing nothing. Large synchronous work
should also provide visible progress or move off the UI thread if it can block a
frame for a noticeable duration.

### Likely location

`TraceLoom.loadLog(from:)` currently reads with
`try? String(contentsOf:encoding:)` and returns immediately on failure. This
suppresses the underlying filesystem or UTF-8 decoding error and explains the
lack of stderr, though it does not by itself establish why size correlates with
the failure. If the read succeeds, the next suspects are the synchronous state
update, parsing, pyramid construction, and editor reconciliation.

### Acceptance criteria

- Reproduce with a saved fixture around the observed threshold and identify
  whether time is spent reading, parsing, reconciling, or rendering.
- Loading a valid UTF-8 log substantially larger than 10 MB either completes or
  reports a clear supported-size/resource error.
- File and decoding errors include the path and underlying error in diagnostics.
- The application remains responsive, or presents explicit progress, during a
  large load.
- Add regression coverage around the confirmed boundary and failure mode.
