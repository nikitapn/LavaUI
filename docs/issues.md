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

**Status:** Fixed
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

### Findings

**There is no size threshold.** A valid UTF-8 log well past the observed
boundary loads and renders completely — confirmed in the running app at 12 MB
(220,000 lines, 345,716 points) and at 57 MB (1,099,996 lines, 1,728,572
points). Measured on a 12 MB / 57 MB fixture pair, debug build:

| stage | 12 MB | 57 MB |
| --- | --- | --- |
| read | 15ms | 86ms |
| split into lines | 402ms | 2,049ms |
| parse | 3,273ms | 16,479ms |
| pyramid build | 47ms | 337ms |
| emit/present | ~17ms | ~17ms |

Parsing dominates and is linear with no cliff; reading is never the cost;
pyramid construction and rendering are negligible, because `visibleLines` caps
what the log `EditorView` ever lays out regardless of buffer size.

**The real cause was the decode, not the size.** `try? String(contentsOf:
encoding: .utf8)` returns nil for the whole file over a single non-UTF-8 byte,
and `loadLog` then returned without a word. Size correlated only statistically:
a bigger real-world log is likelier to contain one stray byte from a mis-encoded
line or a rotation artifact. Reproduced exactly — the 12 MB fixture loads, and
the same fixture with one `0xE9` inserted mid-file produces no visible result
and no stderr.

### Resolution

`LogFile.read(at:)` in `TraceLoomCore` replaces the inline `try?`, so the error
paths are testable without a window:

- Invalid UTF-8 no longer costs the file. It decodes lossily — every valid
  sequence intact, U+FFFD for the rest — and reports the path, the byte offset,
  and the line number of the first bad sequence (`firstInvalidUTF8Offset`, which
  also rejects overlongs and surrogates).
- Read failures throw with the path and the underlying reason
  (`localizedDescription`, not the NSError dump). The previous document is kept.
- Files over a documented 256 MB limit report a resource error instead of
  attempting the allocation; the check runs off file metadata.

Both outcomes go to stderr and to a banner under the header that persists until
the next load.

For progress, `FrameTasks.after` (new, in LavaUI) defers work until after the
current frame is presented. `loadLog` sets "Loading x.log…" and hands the read
and reparse to it, so the status is on screen before the thread blocks —
verified with an external window capture 4s into the 57 MB load. The work still
runs on the main thread; what changed is that the user is told which file is
blocking it.

Coverage: 7 tests in `Tests/TraceLoomCoreTests/LogFileTests.swift`, including
the one-bad-byte case, a >12 MB end-to-end load and parse, the size limit, and
UTF-8 validator edge cases.

### Follow-up: parsing moved off the main thread

The above left parsing synchronous — 3s at 12 MB, 16s at 57 MB. Worse, the
blocking call was not in `loadLog` at all: `body` called
`dataCache.resolve(log:rules:)` directly, so *every keystroke* in the rules
editor reparsed the whole log. The header advertised "live parse"; on a large
log it was a 16s freeze per character.

**Why a worker cannot just write `@State`.** `StateStorage` is `@Observable`,
and `withObservationTracking`'s `onChange` fires synchronously on whichever
thread performed the write. A background write would run
`ViewInvalidation.markBodyDirty` on that thread, racing the run loop's
`consume()` against `pending` and `dirtyBodyNodes` — all single-threaded
statics. So workers compute pure `Sendable` values and nothing else;
only the main thread writes state.

`MainQueue` (LavaUI) is the handoff: `async` is safe from any thread, takes a
lock, and calls `editor.wakeEventLoop()` (`glfwPostEmptyEvent`, documented
thread-safe) so a result can unblock a loop parked in `pumpEvents`. It drains
at the *top* of the loop, before invalidation is consumed — the opposite slot
from `FrameTasks`, which drains after present. `AgentServer` already had this
shape privately; this generalises it.

`TraceDataCache` became stale-while-revalidating: it keeps the last completed
parse, dispatches at most one worker, stamps each request with a generation so
an out-of-order finish cannot overwrite a newer one, and returns the previous
output immediately so `body` never blocks. Below 256 KB it still parses inline
— a thread hop there would blank the timeline for a frame on every edit,
including for the built-in sample. `TraceParser.parse` gained a
`shouldContinue` variant polled every 4096 lines, so a superseded parse is
abandoned rather than run to completion.

`logLineCount` moved into the parse output as well. It was
`log.split(...).count` evaluated in `body` for the disclosure title — ~2s at
57 MB, which would have kept the main thread blocked for as long as parsing
used to and defeated the whole exercise.

Measured with the 57 MB log loaded, typing into the rules editor: worst
main-loop round-trip **20.7ms** across 277 samples, against ~16s per keystroke
before. Threads return to baseline afterwards, and the final render is correct
rather than stale.

### Not addressed

- The `split` in `TraceParser.parse` materialises every line before the loop
  can poll `shouldContinue` once, so a superseded worker still pays ~2s at
  57 MB before noticing. Skipping the regex pass is the other ~90%.
- Reading the file is still synchronous on the main thread (~86ms at 57 MB),
  covered by the `FrameTasks` status frame rather than moved off.

### Follow-up: quadratic decoration ranges

`TraceLoom.lineRange(in:line:)` re-split the whole log and re-summed the
prefix for *every* diagnostic it decorated — O(diagnostics x text). Not a
slow path: a hang. A rule naming a capture group that does not exist emits one
diagnostic per matching line (125,716 on the 12 MB fixture), so a body
evaluation meant ~126,000 full splits of 12 MB. `Expand` builds its content
eagerly (`Expand.swift:24`), so this ran whether or not the log disclosure was
open. Reproduced: the main loop gave no answer for 75s while burning two
cores, against a worst round-trip of **150ms** after the fix.

`LineIndex` (in `TraceLoomCore`, so the off-by-ones are testable) computes all
line offsets in one pass, bounded by the deepest line anything asks about, so
decorating a few early lines of a large log does not index the rest of it.
Decorations are also capped at 500 — nothing downstream can use 126,000 gutter
markers, and building the array cost more than reading it ever saved.

Truncation is stated rather than silent: the diagnostics panel showed three of
125,716 exactly as it showed three of three, and now reports
"+125713 more · first 500 marked in the gutter". The count is also the tell
that a rule is wrong for every line rather than a few.

Coverage: 7 tests in `Tests/TraceLoomCoreTests/LineIndexTests.swift`, checked
against the original `split`-based implementation as an oracle across empty
text, trailing newlines, blank lines, and multibyte characters.
