# Phase 0 results (prep spikes)

Runnable throwaway target: `swift run Phase0Spikes`  
Sources: `Sources/Phase0Spikes/` (delete after Phase 1 lands).

Date: 2026-07-28 · All three spikes **PASSED**.

---

## 0a — Parameter packs for `TupleView`

**Verdict: use packs; no gyb needed.**

| Check | Result |
|-------|--------|
| `buildBlock<each C: View>(_ c: repeat each C) -> TupleView<repeat each C>` | Compiles |
| Runtime type | `SpikeTupleView<Pack{SpikeText, SpikeSpacer, SpikeText}>` |
| `(repeat HostedNode<each C>)` in a class | Compiles |
| Pack iteration → `[LayoutChild]` | 3 children, labels correct |

**Implications for Phase 1**

- `TupleView<each C: View>` + pack `buildBlock` is the path.
- Retained children can store `(repeat HostedNode<each C>)` (or `ViewNode`) and flatten with `for x in repeat each …`.
- No generator / TupleView1…N scaffolding.

**Caveats**

- `Body == Never` still needs a practical substitute (`EmptyView` / empty leaf); packs do not change that.
- `-parse-as-library` was required on the spike target when C++ interop is on (otherwise `@main` + “top-level code” diagnostic). Mirror that on any new Cxx executable if it shows up.

---

## 0b — Yoga measure func from Swift

**Verdict: works as sketched in the plan.**

```
first layout:  24×24, measureCalls=1   // "Hi"
second layout: 200×24, measureCalls=2  // longer text + YGNodeMarkDirty
```

| Check | Result |
|-------|--------|
| Global / static `YGMeasureFunc` (no capture) | OK as C function pointer |
| `Unmanaged.passUnretained(leaf)` → `YGNodeSetContext` | OK |
| First `YGNodeCalculateLayout` invokes measure | Yes |
| `YGNodeMarkDirty` + recalculate re-invokes measure | Yes (1 → 2) |
| Ideal width reflects content when not stretched | Yes (24 → 200 cap) |

**Implications for Phase 2 / 4**

- Text leaves: set measure once when the Yoga node is created; never swap the measure function identity if you can avoid it.
- **Must not stretch** text leaves if you want intrinsic width — use `alignItems: flex-start` (or explicit width) on the parent row. Column + default stretch forces `Exactly` and hides intrinsic size (caught this in the first assertion attempt).
- `YGNodeMarkDirty` only on nodes that have a measure function (as documented).

**Linking note**

- `CYoga` is headers-only in SPM; `YGNode*` symbols resolved via `libcanvas.so` (Yoga linked into canvas). Fine for HelloWorld. If a target uses CYoga *without* CxxCanvas, link `libyoga.a` or compile Yoga sources into `CYoga`.

---

## 0c — `Font::measure` across the boundary

**Verdict: new signature imports cleanly under `-std=c++23`.**

| Check | Result |
|-------|--------|
| `canvas.Font()` construct + move-only type | OK |
| `font.load(std.string(path), 16)` → `VoidResult.has_value()` | true |
| `measure(std.string)` → `TextMetrics` fields | width/height/ascent/descent all readable floats |
| `measure(text, availWidth, mode)` Undefined / AtMost / Exactly | OK |
| Exactly(40) returns `width == 40` | Yes |
| AtMost wraps (height multiplies by line count) | 23 → 92 (4 lines) |

**Observed AtMost overflow**

```
measure AtMost(40): w=65.77 h=92
```

Matches `font.hpp`: an unbreakable word wider than `availWidth` is allowed to overflow the line (CSS/Yoga-style). Phase 4 Yoga measure must use the same rule; do not assert `width <= availWidth` blindly.

**Implications for Phase 4**

- Swift can own a `Font` (move-only) for the process / cache key path.
- Prefer `std.string(...)` when calling C++ APIs that take `const std::string&`.
- Check success with `VoidResult.has_value()` — do not rely on `error()` / `value()` importing.
- Shaped-run cache keys should include `(text, font, availWidth, mode)` as the plan says; Yoga will call measure with different modes on the same node.

---

## Go / no-go for Phase 1

| Risk | Status |
|------|--------|
| Packs unusable → gyb | **Cleared** — packs work end-to-end |
| Measure func impossible from Swift | **Cleared** |
| `TextMetrics` / overload broken under Cxx | **Cleared** |

**Phase 1 can proceed** on:

- `View` / `@ViewBuilder` / `TupleView<each C>`
- Keep current `UI.swift` compiling alongside

No design change forced by these spikes. Carry forward:

1. Align-items / stretch behavior for text intrinsic size.  
2. AtMost long-word overflow.  
3. `CYoga` alone does not link Yoga objects — document for any pure-layout target.
