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
main-loop round-trip **56ms** across 234 samples, against ~16s per keystroke
before. Threads return to baseline afterwards, and the final render is correct
rather than stale.

(Measure agent latency by reading whole JSON objects, not lines. `AgentServer`
pretty-prints its replies, so a `readline()` client desyncs after the first
multi-line response and reports latencies far below the real ones.)

### Follow-up: parsing parallelised by line range

Every log line is independent, so the line range divides across cores. The only
shared state was `matchedLines`, a `Set<Int>` — and since chunks hold disjoint
line ranges, a per-chunk count sums exactly. It is now a single
"already counted this line" marker per chunk, which also drops the set with an
entry per matched line.

Chunk outputs are concatenated **in chunk order**, so the pre-sort array is
identical to the one the serial path built and the sorted result matches
regardless of whether `sorted(by:)` is stable. Diagnostics come out in the same
order for the same reason.

Regexes are compiled per chunk rather than shared. `NSRegularExpression` is
documented immutable and safe for concurrent matching on Darwin, but that is
not the same as having verified it in swift-corelibs-foundation, and compiling
a handful of patterns per chunk is microseconds against seconds of matching —
cheaper to avoid the question than to answer it.

Below 40,000 lines it stays serial: dispatch and per-chunk compilation cost
more than they save. Above that it uses `lines / 20000` chunks, capped at
`activeProcessorCount`.

Measured on 16 cores, debug build, output verified identical to serial:

| fixture | serial | parallel | speedup |
| --- | --- | --- | --- |
| 12 MB / 220k lines | 3,037ms | 811ms | 3.74x |
| 57 MB / 1.1M lines | 15,254ms | 3,870ms | 3.94x |

Short of linear because the `split` ahead of the chunking is still serial —
~2s of the 57 MB figure, which caps the achievable speedup near 5x by Amdahl.
Chunking by byte range instead would recover it, at the cost of finding line
boundaries by hand.

### Not addressed

- The `split` in `TraceParser.parse` is serial and materialises every line
  before any chunk can poll `shouldContinue` once, so a superseded parse still
  pays ~2s at 57 MB before noticing, and it bounds the parallel speedup.
- Reading the file is still synchronous on the main thread (~86ms at 57 MB),
  covered by the `FrameTasks` status frame rather than moved off.
- Pyramid construction is still serial. It is ~2% of the pipeline (337ms of
  16.9s at 57 MB), so parallelising it is worth about 1.02x overall. The
  per-series pyramids are already independent if that ever changes.

### Follow-up: quadratic decoration ranges

`TraceLoom.lineRange(in:line:)` re-split the whole log and re-summed the
prefix for *every* diagnostic it decorated — O(diagnostics x text). Not a
slow path: a hang. A rule naming a capture group that does not exist emits one
diagnostic per matching line (125,716 on the 12 MB fixture), so a body
evaluation meant ~126,000 full splits of 12 MB. `Expand` builds its content
eagerly (`Expand.swift:24`), so this ran whether or not the log disclosure was
open. Reproduced: the main loop gave no answer for 75s while burning two
cores. After the fix the same scenario settles to a worst round-trip of
**1.5ms**.

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

## 4. A single very long line is rendered in full, every frame

**Status:** Open
**Area:** `EditorView` / text shaping / draw-list emission

### Observed

One enormously long line — minified JS, a one-line JSON payload, a log line
with an embedded blob — is shaped and emitted in its entirety, however little
of it is on screen. Measured in TraceLoom, expanding the log editor on a file
whose longest line is the given length:

| longest line | RSS delta | one-off CPU | cost of *each* redraw frame |
| --- | --- | --- | --- |
| 500,000 chars | +390 MB | ~0.7s | — |
| 2,000,000 chars | +1,160 MB | ~3.1s | `emit=295ms present=739ms total=1034ms` |

Roughly 600 bytes and 1.5µs per character of the longest line, linear.

The steady-state number is the serious one. At 2M characters every redraw
costs about a second, so a blinking caret alone makes the window unusable, and
a 5 MB minified file would be ~3 GB and ~2.5s per frame. It does not hang or
crash at these sizes — it degrades until it may as well have.

Note this is *not* the CRLF fault from issue 3. That made a whole buffer
report itself as one line; this is a line that genuinely is that long, and it
survives the fix.

### Expected

Cost should track what is visible, not what exists. VS Code's answer is to
stop rendering past a column budget and offer "[show more]", which is a
product decision as much as a technical one — the alternative is horizontal
culling, which keeps the line fully scrollable and needs no affordance.

### Likely location

Three places each walk the whole line:

- `LeafNode.widestRowWidth` shapes the longest row to size the horizontal
  scroll extent. Candidate selection (issue 3) means only a dozen rows are
  shaped, but if one of them *is* the two-million-character line, that shaping
  still happens and its glyph array stays in `UIFont.shapeCache`.
- `DrawList.text` emits a `GlyphInstance` for every glyph of a visible row
  with no horizontal viewport test, so glyphs scrolled far off either side are
  still built and uploaded. This is what makes it a per-frame cost rather than
  a one-off, and it is the highest-value thing to fix.
- `UIFont.shape` builds and caches a `[ShapedGlyph]` for the whole line;
  `shapeCacheLimit` bounds the *number* of entries, not their size.

### Acceptance criteria

- Emission is bounded by the horizontal viewport: a redraw with a
  two-million-character line on screen costs about what a screen-width line
  costs.
- Shaping is bounded too, or the shaped run for an over-long line is not
  retained — a viewport-sized slice is enough to draw and to hit-test.
- Caret placement, selection, and click-to-index stay correct for offsets
  beyond whatever bound is chosen, or the bound is a visible truncation the
  user can act on rather than a silent one.
- A decision is recorded on truncate-with-affordance versus cull-and-scroll;
  they imply different editing semantics for the hidden tail.
- Regression coverage at a line length well past the bound.

## 5. Changing the UI scale only re-measured text from one key handler

**Status:** Fixed
**Area:** content scale / text metrics / layout invalidation

### Observed

`FontStore.zoomIn(into:)`, `zoomOut(into:)` and `resetScale(into:)` swapped the
active face and cleared the shared measure cache, but did not cause Yoga to
re-measure anything. Only one caller made it work: the `Ctrl+Shift+±`/`0`
handler in `LavaApp.run`, which followed up with
`host.invalidateTextMetrics()` and `dirty = true`.

Every other caller got a silently wrong layout — the new font drawn into boxes
sized for the old one. Reached from a menu item, a button, or an agent script,
zoom looked broken in a way that pointed nowhere near the font code.

The asymmetry was invisible from the call site. `zoomIn(into:)` returns `Bool`
and reads like a complete operation; nothing in its signature suggests the
caller still owes the layout an invalidation, and nothing could discharge that
debt anyway — `invalidateTextMetrics()` needs the `LayoutHost`, which only
`LavaApp.run` holds.

### Expected

Changing the scale should re-measure, whoever asked for it. A framework API
that requires a follow-up call the caller cannot make is not usable outside the
one place that already has the internals.

### Resolution

`FontStore.metricsGeneration` is bumped by `apply(scale:into:)` — the single
funnel every zoom helper already goes through. The run loop records the last
value it saw and calls `host.invalidateTextMetrics()` when it moves, once per
iteration, after input and menu activations so a change from any of them
re-measures before the frame lays out.

A counter rather than a callback because the fix has to hold for callers the
framework has never heard of. The key handler's special case is gone; it now
just calls `ContentScaleShortcuts.handle` and lets the central path do the
invalidating, so there is one implementation instead of one plus a rule to
remember.

Verified in HelloWorld by driving **View → Zoom In** twice through the real
DBusMenu: `ui scale → 1.25x` then `1.50x`, with the toolbar visibly re-laid out
at the larger size rather than clipped into old boxes. The keyboard chord still
works after losing its inline invalidation.

### Note for callers

Menu items that change scale should carry no shortcut. Menu matching runs
before `ContentScaleShortcuts` and consumes the event, so binding
`Ctrl+Shift+=` to a "Zoom In" item shadows the built-in handler rather than
duplicating it.

## 6. Images were never batched, never released, and unsafe to release

**Status:** Fixed
**Area:** texture management / draw batching / GPU lifetime

### Observed

Four separate defects, found while costing out a client that shows a wall of
album covers. Any one of them makes that screen impossible.

**Every distinct texture broke the batch, and past 64 the wrong one drew.**
The quad shader has a single `sampler2D`, so each image ended the batch and
started a new draw. Worse, a frame has only `kMaxDescriptorSetsPerFrame` (64)
descriptor sets; at `quad_renderer.cpp:904` the write index was clamped to the
last slot and *reused*, overwriting a descriptor an earlier batch had already
bound. Past 64 images the result was not an error or a dropped draw — it was
the wrong picture, silently.

**Nothing was ever released.** `ImageStore` cached by path and never evicted;
`UIImage`'s own doc said the texture id "is stable for the process lifetime".
`TextureManager::unloadTexture` existed in C++ but was not bridged to Swift at
all, so there was no way to free anything. Scrolling 2,000 covers at 300×300
RGBA pins ~700 MB that never comes back.

**Releasing would have crashed anyway.** `unloadTexture` called
`vmaDestroyImage` immediately, with no fence and no deferred queue. Freeing a
texture an in-flight frame still references is a use-after-free.

**Decoding blocked the UI thread.** `loadTexture` did `stbi_load` and the GPU
upload together — the same shape as the synchronous log parse in issue 3.

### Resolution

`ImageAtlas` packs images into 2048² RGBA pages, so a hundred covers cost one
descriptor bind and one draw. Slots rather than the shelf packing the glyph
atlas uses: glyphs vary wildly and are never individually freed, while cover
art is uniform and very much needs freeing, and a fixed cell grid makes the
free list trivial where tight packing would need compaction. Images larger
than a cell stay standalone. UVs cover only the pixels written, so a smaller
image cannot sample its neighbour. `TextureHandle` carries `uv0`/`uv1` and
`application.cpp` passes them to `pushImage`, which already accepted UVs and
was hardcoding `[0,1]`.

`Vulkan::destroyImageDeferred`/`collectGarbage` retire resources
`kMaxFramesInFlight + 1` frames later — the `+1` because the frame being
recorded has not been counted yet and can still name the image — drained per
present and again after the device wait in `cleanUp`. `Editor.unloadImage`
bridges it, so the path is reachable rather than dead code.

Decode split from upload: `Engine::decodeImageAlloc` touches no Vulkan and is
safe from a worker; `uploadTexture` stays on the device thread.
`ImageStore.imageIfLoaded` decodes on a worker, posts the upload through
`MainQueue`, and returns nil meanwhile so the caller draws a placeholder.

Eviction is by byte budget, not visibility. Dropping a poster when it scrolls
off thrashes — reverse direction and everything just discarded must be decoded
again. Visibility belongs in *priority*, a budget in *lifetime*. Nothing is
evicted on a frame it was drawn, so a visible set larger than the budget stays
over budget rather than painting holes. `touch()` is called from the draw list
*after* the cull test that skips whole subtrees, so least-recently-used means
least recently **drawn**.

### Found on the way

`transitionImageLayout` had no `SHADER_READ_ONLY → TRANSFER_DST` case, which
is exactly what uploading a new cell into a page already being sampled needs.
It `throw`s on an unsupported transition, and a C++ exception crossing into
Swift aborts the process — so the first atlas run died with SIGABRT rather
than reporting an error. Any transition added later has the same trap.

### Verified

100 distinct 200px posters plus the demo logo landed in **2 pages, zero
standalone**, rendering distinctly with no cell bleed; previously 101 textures
would have silently drawn wrong art past 64. Unloading them while on screen
survived, as did unloading 8 standalone 512px textures — the path that
actually exercises deferred destruction, since atlased images only return a
cell. With a 4 MB budget over 16 MB of posters the settled cache went from
15641 KB / 101 images to **6562 KB / 42**.

Two bugs in the eviction policy itself were only found by instrumenting it:
it ran on insert alone, so the cache sat over budget once loading stopped; and
`endFrame` ran on every loop iteration including idle ones that render
nothing, which looks like "nothing was drawn" and evicted the on-screen images
straight into a reload.

### Not addressed

- The silent descriptor clamp at `quad_renderer.cpp:904` is *mitigated*, not
  fixed. The atlas keeps ordinary UI well under 64 binds, but a screen with
  more than 64 images too large to atlas still draws the wrong ones without
  saying so. It should at least warn.
- Request windowing is the app's job. A view that asks for every image on
  every body — regardless of which rows are on screen — churns, because the
  budget evicts what is never drawn and the next body asks again. The
  framework cannot infer which images are about to matter.
- No mipmaps, so a cover drawn much smaller than its source aliases.
