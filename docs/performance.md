# Performance suite

`LavaBench` is a fixed set of scenarios that drive the real frame pipeline and
compare the result against a checked-in baseline. Run it after any change that
touches text, layout, the draw list, or the image cache.

```sh
swift build -c release            # release, always — see below
./.build/release/LavaBench        # exit 0 = no regression, 1 = regression
```

## Why it exists

Every performance bug this repo has had was invisible until it was measured,
and none of them were found by a test:

- Opening a 10 MB log in TraceLoom took **601 ms** because four separate
  `O(buffer)` operations ran per mount. The output was correct. Nothing failed.
- Find-in-file over the same log **never finished** — `String.range(of:)` per
  match, each converting an index to an `NSRange` by measuring from
  `startIndex`. That one was found by the first run of this suite.
- Typing at the end of a 10 MB buffer cost **64 ms per keystroke** — four full
  grapheme walks of the buffer per key, to record a character offset in the
  undo history and to put the caret back. Also found by this suite; the fix
  moved the edit path to UTF-8 offsets and took it to 6 µs.
- A slider drag spent 4.3 ms per pointer move in Yoga and only *looked* like
  the knob lagging.

A correctness suite cannot catch any of these, and "does the app feel slow" is
not something anybody notices in the same week as the commit that caused it.

## Counters, not just times

Every scenario reports two kinds of number, and they are gated differently.

**Counters are exact and any change fails the run.** How many lines were
shaped, how many Yoga measure calls ran, how many images were decoded, how many
nodes were laid out. These have no variance — an algorithmic regression changes
*how much work happens*, and that is the same integer on a busy laptop as on an
idle one. `list.lazy-grid-5000` laying out 146 nodes instead of 5,000 is the
whole guarantee of `LazyVGrid`, and it is a counter.

**Times are noisy and get a 50% tolerance.** Reported per pipeline stage under
the same names `LAVAUI_DEBUG=1` prints (`body` / `layout` / `emit`), so a bench
row and a line from a real run read against each other. Each scenario's number
is the **minimum** across repetitions, not the mean: every source of noise makes
a run slower and never faster, so the fastest repetition is the closest thing to
the cost of the code. Stages under 0.3 ms are not compared at all.

Adjust the timing gate with `--tolerance <percent>` if a machine is noisy.
There is no equivalent for counters, deliberately.

## Debug builds are meaningless here

Swift's unoptimised `String` and `Array` code is slow in ways that have nothing
to do with the algorithm — every earlier investigation in this repo that
trusted a debug measurement chased the wrong function. `LavaBench` prints a
warning if it was built `-c debug`; take it seriously.

## Why it opens a window

Text is shaped by the engine and the draw list writes into engine-owned
storage, so text measurement — what most of these scenarios are about — does
not exist without an `Editor`. The window is opened and then ignored: nothing
is presented, no events are pumped, the swapchain is never touched. Present
time is dominated by vsync, which would put a 16 ms floor under every
measurement and hide exactly the CPU-side costs this exists to find.

Consequences: **a display is required**, and a blank window sits on screen for
the length of the run. That is not a hang.

This is also why `LavaBench` is an executable and not a test target. `swift
test` should stay headless and fast.

## Usage

```sh
./.build/release/LavaBench                       # check against the baseline
./.build/release/LavaBench --verbose             # per-scenario counters and spread
./.build/release/LavaBench --filter editor       # one area, while iterating
./.build/release/LavaBench --list                # scenario names
./.build/release/LavaBench --json out.json       # raw results
./.build/release/LavaBench --update-baseline --notes "why"
```

`--filter` and `--iterations` disable counter gating: the font shape cache and
the image cache carry over between scenarios, so half a run legitimately
produces different counts. `--update-baseline` refuses to record from a partial
run, and refuses to record a run whose own assertions failed.

## Re-recording the baseline

`Benchmarks/baseline.json` is committed. Re-record when a change is *meant* to
move the numbers, and say so in `--notes` and in the commit message. A baseline
is "this must not get worse", not "this is good enough" — some rows in it are
known-slow (see below) and are there to stop them getting slower.

Baselines are machine-specific. A recording from a different machine will
produce noise, not signal; re-record locally before trusting a comparison.

## What the scenarios cover

| prefix | what regresses if it moves |
|---|---|
| `text.*` | buffer logic — wrapping, editing, undo, search. No window, no Yoga. |
| `editor.*` | a mounted `EditorView`: mount, reconcile, redraw, decorations |
| `list.*` | `LazyVGrid` virtualization — mount only what the viewport shows |
| `image.*` | `ImageStore` decode, cache hits, and eviction under a scrolling grid |
| `traceloom.*` | `TraceParser` over a large log |

`editor.open-200-lines` is a control: if it moves, the regression is fixed
overhead in the editor path and not anything size-dependent, which is a
different bug with a different fix.

Some scenarios also assert. `text.select-all-delete-10mb` checks that no stale
row table survives the delete; `image.poster-scroll-thrash` checks that the
cache stays under budget and does not re-decode on every visit;
`list.lazy-grid-*` checks the node count. An assertion failure fails the run
regardless of timing.

## Known-slow rows

These are recorded in the baseline as they are. They are real, user-visible
costs that have not been fixed yet — not measurement artifacts.

- **`text.logical-rows-10mb-unicode` — 152 ms vs 9 ms for the ASCII path.**
  A single non-ASCII character anywhere disqualifies `SoftWrap`'s byte scan for
  the whole buffer, and the grapheme walk is 16x slower. Expected, but it is
  the cost a user with a non-English log actually pays.
- **`traceloom.parse-10mb` — 457 ms.** Already parallel across cores; the
  floor is the `split` that materialises every line.

## Where the frame actually goes

Measured 2026-08-05, release build, with the LavaUI producer and renderer in
separate processes, so every number below crosses a real boundary. The view is
a `ForEach` of rows inside a
`ScrollView`, grown by clicking a button in the running app.

| per frame | 60 rows | 560 rows |
|---|---|---|
| `body` | — | **3.3–3.7 ms** |
| `layout` | — | **4.0–5.5 ms** |
| `emit` (producer) | 0.04 ms | 0.08 ms |
| `replay` (renderer) | 0.026 ms | 0.031 ms |
| commands on the wire | 58 | 58 |

**Fifty-eight commands either way.** That is the number worth remembering: the
draw list is already bounded by the viewport rather than by the tree, because
`DrawList` culls as it walks. Growing the tree tenfold changed what crosses the
boundary not at all, and changed replay by 5 µs.

Corroborating, from the same session: HelloWorld maximized to 3400×1800 is 375
commands, 2261 glyphs, **0.12 ms** to replay. `editor.open-10mb` in this suite
is emit 0.05 ms against layout 21.5 ms.

### What this rules out

A **partial draw list** — publishing only changed subtrees against a persistent
tree in the renderer, with the versioning and change log that implies — would
optimize the two cheapest stages in the pipeline. Emit plus replay is 0.11 ms
on a frame where body plus layout is 9 ms. It was planned, and the measurement
is why it has not been built.

The premise was right and the attribution was wrong. "A client that changes one
label rewrites its whole list" is true, and that rewrite costs 0.08 ms. What it
*also* does is re-run `body` for the whole subtree and re-lay-out the whole
tree, and that is the 9 ms. The problem is real; it is in layout, not on the
wire.

The one case partial emit would genuinely win is a flat, non-lazy list of tens
of thousands of children, where the walk visits every node just to cull it
(~143 ns each). `LazyGrid` already covers that, by not mounting them.

### Where it went instead: Yoga had nothing to skip

Following the 9 ms, on the same 560-row client. Yoga tracks dirty subtrees and
skips clean ones, so a body pass that changed one label should re-lay-out
almost nothing. It re-laid-out everything:

| on a frame where one label changed | before | after |
|---|---|---|
| dirty Yoga nodes | **2249** of 2813 | **6** of 2813 |
| measure-function calls | 1124 | **2** |
| `YGNodeCalculateLayout` | 3.8–4.4 ms | **0.57–0.63 ms** |
| `layout` stage | 4.0–5.5 ms | **1.1–1.3 ms** |
| whole frame | 7.5–9.3 ms | **4.3–4.6 ms** |

Three separate things were dirtying the tree, and the first two hid the third:

1. **Every `Text` reconcile marked its leaf dirty unconditionally.** The
   comment said it was for content-scale changes, which swap the face without
   changing the string — but that case is already handled centrally by
   `LavaWindow.syncTextMetrics`, and the same function already computed the
   font-identity comparison that answers it exactly.
2. **`calculateLayout` folded `!layoutValid` into `sizeChanged`,** and
   `setRoot` clears `layoutValid` on every body pass to stop hit-tests running
   against stale frames. So every body pass took the "the viewport changed,
   re-measure every leaf" branch. "Layout is stale" and "every measurement is
   stale" are different claims.
3. **Every container relinked its Yoga children on every reconcile.**
   `YGNodeRemoveAllChildren` discards each child's layout and
   `YGNodeInsertChild` dirties the container and every ancestor — so each of
   the 561 rows dirtied itself and its chain, every frame. This was the big
   one, and the fix is one pointer compare per child: reconcile returns the
   same node objects in the same order unless something was inserted, removed
   or reordered, which is the entire point of reconciling.

Found by counting rather than reading: a temporary probe printed dirty nodes
before `YGNodeCalculateLayout`, broken down by node kind, and the counts summed
exactly — 1122 text + 561 spacer + 561 HStack + 2 VStack + 2 button + 1
ScrollView = 2249. A second probe compared `YGNodeRef` pointers between passes
to rule out remounting (`fresh=0`), which is what pointed at re-dirtying in
place rather than rebuilding.

### And then `body` was the view's fault, not the framework's

With layout fixed, `body` was the largest stage at ~3 ms. Two hypotheses, both
worth recording because the first was wrong and the second was not a framework
problem at all.

**Wrong:** per-node string work. `Text.reconcilePrimitive` builds a debug label
by interpolation on every reconcile, and `shortLabel` calls `string.count`,
which is O(n) on a Swift `String` — 1122 allocations and 1122 grapheme walks
per frame, for something only structure dumps and agent queries read. Plausible
and false: a `perf` profile showed no string cost in reconcile at all. It is
flat Swift-runtime overhead — retain/release ~7%, dynamic casts ~2%, generic
metadata instantiation ~3%, exclusivity checks ~3% — with no hot spot to
remove.

**Right, and it is not a cost at all:** `ViewInvalidation` tracks the composite
node that *read* the value, so which subtree a change recomputes is decided by
where the state lives. The demo had `@State private var clicks` on the same
view that built the 560-row list, so pressing a counter recomputed the list.
Moving the counter into a view of its own:

| pressing the counter, 560 rows | `@State` on the root view | on its own view |
|---|---|---|
| `body` | 3.30 ms | **0.02 ms** |
| whole frame | 4.0 ms | **0.67 ms** |

165× on the stage, and the framework needed no change — per-node body
invalidation already worked. Together with the layout fix, the same
interaction went from ~8 ms to 0.67 ms.

The lesson is a real one and nothing announces it: **state placement is a
performance decision.** A counter sharing a view with a long list makes every
press cost the list. This is the same rule SwiftUI has and the same way it is
usually learned, which is an argument for a diagnostic rather than for
documentation alone.

What is left in `layout` (0.5 ms with `body` at 0.02) is the work
`calculateLayout` does regardless of what changed: `collectFrames` builds a
`LayoutFrame` — with a `String` — for all 2249 nodes on every pass, for
hit-testing and agent queries. That is the next thing to look at if this stage
matters again.

### Where the compositor's servant work runs

The control plane's servants used to run on the shared-memory ring thread and
hop to the render loop by hand, once per method, via a `LoopQueue.sync` that
each of them had to remember. They now run *on the loop* — NPRPC's POA carries
the placement (`dispatch: .loop(…)`, see nprpc `docs/POA.md`), so touching
Vulkan from an RPC thread stopped being something you can express.

Measured 2026-08-06, release, launch → the client's "client up" banner:

| | hand-rolled hop | POA dispatch |
|---|---|---|
| first client (compositor cold) | 136 ms | 120 ms |
| later client (assets cached) | 112, 113 ms | 105, 126 ms |

**Parity, which is the result worth having**, because the change moved image
decoding *onto* the loop and the question was what that costs. It costs nothing
here: the client is blocked on the reply either way, so which thread decodes
does not change its critical path.

Where it does land is on *other* clients' frames — a first-ever decode is
5–17 ms during which the loop is not drawing anything, for anyone. Bounded by
the servant's own cache: an asset is decoded the first time this compositor
sees it and never again, so the cost is a few dropped frames per image per
boot. Two things follow, if that ever matters: the split that avoids it needs
either a per-method dispatch policy or an interface split, and an interface
split would be letting the renderer's threading shape the wire.

The ring is also free immediately now, which the old shape could not do:
`CreateSurface` builds a swapchain and takes ~86 ms, and that used to be 86 ms
during which nothing else from that client — its input acks included — could be
read.

### A harness gap found on the way

Agent-injected clicks do not reach handlers on a client that is *also* fed by a
compositor input stream: the hit test finds the node, but the state change
never lands. Real input through the compositor works, and injection works on a
standalone client (`LAVA_CLIENT=1 HelloWorld`), so it is specific to a window
with two input sources. Not chased down.

It matters beyond convenience: the first `perf` profile above was taken while
driving clicks through the agent, which means it profiled the agent server
answering rather than the body passes it was supposed to measure. The numbers
quoted are from a re-run driven with real input.

### What to measure before revisiting

- **Many clients.** Every number above is one. If a renderer driving 10–20
  surfaces does not stay flat, partial lists get a real justification. A
  multi-threaded renderer is the other answer to that question, and probably
  the better one — Vulkan is built for it, one `VkQueue` per thread, and it
  scales with windows rather than with what changed inside them.
- **Content that cannot be culled.** Everything here is bounded by the viewport
  because it is 2D and rectangular. That is an assumption, not a law.

### Reproducing

Temporary instrumentation, added and removed each time rather than left in:
`LAVAUI_DEBUG=1` on the producer gives the per-frame `body`/`layout`/`emit`
line; the replay number came from a `steady_clock` pair around
`replayDrawList` in `RenderWindow::render`, gated on an env var.

## Adding a scenario

Scenarios live in `Sources/LavaBench/*Scenarios.swift` and are registered in
`main.swift`. A scenario names its own stages:

```swift
Scenario(
    "editor.open-10mb",
    detail: "mount + layout + emit an EditorView over a 10mb log",
    iterations: 3,
    body: { harness, rec in
        let box = TextBox(Fixtures.logOfApproximately(megabytes: 10))
        harness.frame(editorView(box), into: rec)   // times body/layout/emit
        rec.counter("bufferKB", box.text.utf8.count / 1024)
    }
)
```

Rules of thumb:

- **Put a counter on the thing you actually care about.** A timing row tells
  you something got slower; a counter tells you what changed.
- **Fixtures must be deterministic** (`Fixtures` uses a seeded splitmix64). A
  baseline that depends on whichever log file was lying around is not a
  baseline.
- **Build fixtures outside the timed stage.** `Fixtures` caches generated
  strings for this reason.
- **Watch for caches below you.** `image.poster-decode-cold` runs one
  repetition because the engine's `TextureManager` keeps its own ref-counted
  copy, so repetitions 2..n measure an engine cache hit — 0.05 ms against the
  first run's 59 ms.

## Related tools

- `LAVAUI_DEBUG=1` — one timing line per rendered frame in a real app run.
  Idle frames print nothing, because idle frames are not rendered.
- `LAVAUI_PROFILE=1` — per-widget paint cost; `WidgetProfiler.snapshot()`, and
  the `profile` agent command. Answers "which widget", where the frame line
  answers "which stage".
- `perf record -F 999 -g -p <pid>` — the last resort, and the only one that
  names a function. Attach by exact pid (`pgrep -x TraceLoom`); `pgrep -f` also
  matches wrapper shells and will attach to the wrong process.

## Correctness under stress

`Tests/LavaTextTests/EditStressTests.swift` runs ~30,000 seeded random edits
against buffer invariants (every row range addressable, caret in range,
selection materialisable). It is not a benchmark, but it exists for the same
reason: the crash it was written for — deleting a selection left a row table
describing the old buffer — was reachable from any length-changing edit, and
hand-written cases only ever covered the one somebody happened to try. It found
`setText` leaving the same stale table behind on its first run.

Failures print their seed and step and reproduce exactly.
