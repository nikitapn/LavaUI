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
