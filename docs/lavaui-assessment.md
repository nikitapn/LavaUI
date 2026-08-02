# LavaUI framework assessment — August 2026

Written after LavaSpotify, the third app on the framework (HelloWorld, TraceLoom,
LavaSpotify). TraceLoom stressed text and threading; LavaSpotify is the first app
built out of **many images and a continuously-updating model**, and it exercises
parts of the stack the other two never touched.

This is an assessment, not a bug list: what holds up, what is measurably wrong,
and what is simply absent. Everything below is either quoted from code or
measured on this machine — where a claim is analysis rather than observation it
says so.

Sections marked **[fixed]** were addressed in the same pass that produced this
document; their before/after numbers are recorded because the *shape* of each
problem is the transferable part, not the patch.

## Method

- Build: `swift build -c release --product Spotify`, `LAVAUI_DEBUG=1` frame
  timings, real X11 input via `xdotool`.
- Tree size measured via the agent's `layout_tree`; library inflated to 1320
  albums with a temporary env-var fanout in `SpotifySession`, since reverted.

Three traps worth knowing before trusting any measurement taken here:

1. **Debug builds are ~10× slower than release on this path.** Same view, same
   window: `body=4.98 layout=5.31` debug vs `body=0.82 layout=0.18` release. The
   setup guide tells you to `swift run Spotify`, which is debug — so the
   framework feels far heavier during development than it is.
2. **The agent's `settle()` renders outside the instrumented block**, so agent
   clicks produce *no* frame lines. Drive with `xdotool` when timing.
3. **The engine's `std::cout` is block-buffered when redirected.** Atlas and
   texture diagnostics sit in the buffer for a long time; a `grep` against the
   log will happily report zero and read as "this never happened". Run under
   `stdbuf -o0`. This one cost real time — see D1.

## What holds up

The redraw path is genuinely good, and it is the part that carries interaction.

On the 1320-album library — **6643 layout nodes** — scrolling and hovering stay
at redraw level and cost about a millisecond total:

```
frame redraw body= 0.00 layout= 0.00 emit= 0.15 present= 0.62 total= 0.80 ms
frame redraw body= 0.00 layout= 0.00 emit= 0.23 present= 0.80 total= 1.07 ms
```

`emit` is 0.2ms on a 6643-node tree because `DrawList` culls against the
viewport, so **drawing is already virtualised**. The `InvalidationLevel`
cascade, the scroll-offset-on-the-node fix, and the cull stack are all doing
exactly what they were built to do.

Also solid: the `MainQueue` cross-thread discipline (LavaSpotify has four
background threads — catalog, search, seek, poll — and no data races), the
image cache's budget eviction, and `@Bindable` removing the binding boilerplate.

---

## Defects

### D1. No cover in LavaSpotify was ever atlased **[fixed]**

The atlas built for exactly this use case never fired for it.

- `ImageAtlas::add` rejects anything larger than a cell:
  `if (w == 0 || h == 0 || w > cellSize_ || h > cellSize_) return out;`
  (`image_atlas.cpp:68`), cell size 256 (startup log: `64 x 256px cells`).
- `Album.preferredCover` picks the image nearest **300px** (`Models.swift:90`).
- Every cached cover on disk is in fact 300×300:

  ```
  $ identify -format "%wx%h\n" ~/.cache/LavaSpotify/covers/* | sort | uniq -c
       38 300x300
        1 300x297
        1 300x288
  ```

300 > 256, so every cover took the standalone-texture branch: **zero atlas pages
allocated, zero covers atlased**, one descriptor binding each.

Fixed by decoding to the size actually drawn (P4) rather than by growing the
cell — a 140pt cover has no use for 300px, and shrinking the decode fixes the
memory cost and the atlas miss with one change. Confirmed: the log now reports
`ImageAtlas: allocated page 0`, and all 22 shelf covers share it.

Two notes for whoever revisits this:

- **The census is a trap.** `uploadTexture` — the path Swift actually uses —
  logs nothing in either branch, while the older path-based `loadTexture` logs
  both `Atlased texture` and `Loaded texture`. Counting *those* lines reports
  zero regardless. `addPage()`'s `allocated page` line is the only trustworthy
  signal, and only under `stdbuf -o0`. I read a buffered log as "still not
  atlasing" and nearly went looking for a second bug.
- **UI scale can push covers back out.** The decode cap is
  `box × FontStore.scale.multiplier`, so above roughly 1.8× a 140pt cover
  exceeds the 256px cell again and silently returns to its own texture. Raising
  the cell to 512 would cost 16 cells per 2048² page instead of 64; worth doing
  only when someone actually runs zoomed.

### D2. Past ~30 distinct images in a frame, the wrong picture draws **[warns now, not fixed]**

`quad_renderer.cpp:904`:

```cpp
if (fr.descriptorWriteIndex >= kMaxDescriptorSetsPerFrame) {
  fr.descriptorWriteIndex = kMaxDescriptorSetsPerFrame - 1;
}
```

Past 64 the index is pinned to the last slot and that one set is rewritten for
every subsequent bind, so **every texture after the limit draws whatever was
written last**. No error, no validation trip, no dropped draw — just wrong
covers. This was recorded in issue 6 as "mitigated by the atlas"; D1 meant it
was not mitigated at all in the app that needed it.

The effective ceiling is lower than 64. Batches break on any texture change
(`ensureBatchTexture`, `quad_renderer.cpp:518`) and are drawn in submission
order with no sorting, so a grid alternates cover → glyph atlas → cover → glyph
atlas. At roughly two binds per card the ceiling is nearer **~30 covers per
frame** than 64.

By my arithmetic the current layouts sat just under it (~18–21 covers visible in
the library grid at 1280×800), and I never observed corruption in the running
app. D1's fix removes the pressure entirely for atlased images — covers now
share one page view and one descriptor set between them.

The clamp itself still stands, because the *right* fix is a bindless or
sorted-batch design rather than a bigger constant. It now warns once on stderr
instead of failing silently, which is the part that mattered: a silent clamp
turns a renderer limit into what looks like an application data bug.

### D3. The present mode was hard-coded, and MAILBOX is not available here **[fixed]**

The swapchain named a present-mode constant and threw the queried list away
(`(void)presentModes; // listed for diagnostics only`). Three modes were tried
over time — IMMEDIATE for a long stretch, then MAILBOX — by editing that
constant.

The trade behind it is real and was made knowingly, so it is recorded in the
code now rather than contradicted by a stale comment:

| | tearing | latency |
| --- | --- | --- |
| FIFO | none | blocks on vsync — the lag that made a TraceLoom boundary drag trail the cursor |
| IMMEDIATE | possible | lowest; ran here for a long time without tearing being observed |
| MAILBOX | none | no queue buildup — the one we actually want |

**But this surface does not support MAILBOX.** Confirmed twice, independently:

```
$ vulkaninfo | grep -A4 'Present Modes'
    Present Modes: count = 4
        PRESENT_MODE_FIFO_KHR
        PRESENT_MODE_FIFO_RELAXED_KHR
        PRESENT_MODE_IMMEDIATE_KHR
        PRESENT_MODE_FIFO_LATEST_READY_KHR
```

and by forcing the old hard-coded value with validation layers on:

```
VUID-VkSwapchainCreateInfoKHR-presentMode-01281
vkCreateSwapchainKHR(): pCreateInfo->presentMode (VK_PRESENT_MODE_MAILBOX_KHR)
is not supported
```

So requesting MAILBOX was a spec violation the NVIDIA driver happened to
tolerate. Whatever it substituted is undefined — which means any impression
formed while "running MAILBOX" was formed on something else.

`VK_PRESENT_MODE_FIFO_LATEST_READY` *is* available, and it is MAILBOX's
behaviour under another name: present the most recently finished image at the
next refresh and discard the ones it overtook. Non-tearing, no latency buildup.
It needs the `VK_KHR_present_mode_fifo_latest_ready` device extension plus its
feature flag, both requested only when the device advertises them — adding the
extension to the suitability list up front would make a GPU without it fail to
qualify as a device at all.

Selection is now `MAILBOX → FIFO_LATEST_READY → IMMEDIATE → FIFO`, chosen from
what the surface actually reports. IMMEDIATE ranks above plain FIFO on purpose:
FIFO's blocking present is the lag this app moved away from, and a surface
offering neither of the first two leaves it as the only low-latency option.
FIFO is the guaranteed floor.

This machine now runs `present=FIFO_LATEST_READY` with zero validation errors,
and it has been confirmed by hand on the case that started all of this — a
TraceLoom boundary drag, which no longer trails the cursor. So the mode does
deliver what MAILBOX was being reached for, and does it legitimately.

`LAVA_PRESENT_MODE=fifo|mailbox|immediate|latest` forces one for A/B'ing the
latency by feel, falling back with a message rather than tripping the same VUID.
Worth keeping: the drag latency this trade is about is not visible in the frame
log. The app renders only on input, so presents are sparse enough that FIFO
rarely blocks and every mode times about the same — measuring `present=` says
nothing, and the only reliable instrument is a hand on the mouse.

The portability question that prompted this — whether macOS/MoltenVK exposes
MAILBOX — no longer needs an answer. The code asks the surface instead of
assuming, so a platform without it degrades through the chain on its own.

---

## Performance gaps

### P1. Body and layout were O(whole tree) **[fixed]**

The emit path culls; the body and layout paths did not. Measured, release build,
same window, clicking between views:

| View | Nodes | body | layout | total frame |
| --- | ---: | ---: | ---: | ---: |
| Search | 45 | 0.7 ms | 0.1 ms | ~1.0 ms |
| Home | 171 | 4.1 ms | 0.5 ms | 5.5 ms |
| Library (1320 albums) | 6643 | **32–34 ms** | **12–14 ms** | **45–49 ms** |

So any `.body` invalidation on a large list cost ~46ms — 21fps for a single
state change, on a tree the same frame drew in 0.2ms.

`LazyVGrid` / `LazyVStack` (`LazyGrid.swift`) close it. The container reserves
the full scroll extent as its own height, so the scrollbar and wheel clamping
still see the real content size, but mounts only the cells the viewport can show
(plus two rows of overscan). Same library, same window:

| | nodes | switch to library | scroll |
| --- | ---: | ---: | ---: |
| wrapping `HStack` | 6643 | 45–49 ms | ~1 ms (redraw) |
| `LazyVGrid` | **253** | **2.3–3.5 ms** | ~1 ms (layout) |

Three design points worth keeping:

- **Fixed cell size is deliberate.** Variable heights need either a measure pass
  over every item — the exact cost being avoided — or estimate-and-correct,
  which makes the scrollbar jitter as estimates are replaced by truth. A fixed
  stride makes offset→index exact and O(1), and every list these apps have
  (cards, track rows, log lines) is uniform.
- **Windows settle after Yoga, not before.** A container cannot pick a window
  until it knows its own width (for the column count), its position inside the
  scrolled content, and its scroll container's height. None exist until layout
  has run, so `LayoutHost.calculateLayout` settles lazy windows afterwards and
  re-runs Yoga if that changed anything, bounded to three passes. The viewport
  height is read from the scroll node's Yoga box rather than
  `ScrollNode.viewportLength`, which is only assigned during *emit* — using it
  would mount an empty window on the first frame and flash a blank list.
- **Scrolling raises `.layout`, not `.redraw`,** but only when the scroll view
  actually contains a lazy container; ordinary scroll views keep the cheaper
  path. `LazyGridNode` also keeps a live count so an app with no lazy content
  never pays for the tree walk that looks for them.

Verified beyond the timings: hit-testing is correct at a scroll offset (clicking
a card 320px down the scrolled grid opened that album, not its unscrolled
neighbour), and the end of the list renders the right partial row — 1320 albums
at 7 columns is 188 full rows plus 4, which is what draws.

Cell state does not survive scrolling: a cell leaving the window is unmounted
and its `@State` is gone when it returns. That is standard for virtualization
and is documented on the type, but it is a real behavioural difference from the
eager containers.

### P2. An app with a menu got no per-node body invalidation at all **[fixed]**

`LavaApp.swift` used to read:

```swift
if menuHost != nil {
    installRoot()          // full remount, every body frame
} else if let dirty = ViewInvalidation.consumeDirtyBodyNodes() {
    ...
```

The comment was honest about why — `menu` is a free closure, not a mounted node,
so per-node recompute would leave the strip's `MenuModel` stale. But **all three
apps have menus**, so the targeted-invalidation machinery
(`markBodyDirty`/`consumeDirtyBodyNodes`) was dead code in every real program,
exercised only by an app with no menubar.

The fix was smaller than expected because `MenuHost.update` *already* returned
whether the platform-facing model changed. Rebuilding the menu IR every body
frame is cheap — it builds a menu description, not a view tree — so that still
happens unconditionally; only a genuine model change now remounts the root.
`MenuController.update` re-stores item actions regardless of equality, so a menu
whose labels are unchanged but whose closures captured newer state still
activates against the new ones.

### P3. No mipmaps — minification aliases

`maxLod = 0.0f` (`vulkan.cpp:706`) and no `mipLevels` anywhere in
`texture_manager.cpp`. Still open, but much less visible now: covers are decoded
at draw size, so the 2.1× minification that made every card shimmer is gone. It
returns for any image drawn much smaller than its decode cap.

### P4. Decode was always at native resolution **[fixed]**

`decodeImageAlloc` now takes a `maxPixelSize` cap on the longer edge and
resamples with `stbir_resize_uint8_srgb`. `Image(path:width:height:)` derives
the cap from its own layout box × `FontStore.scale.multiplier`, so callers get
it without asking.

One thing worth stating explicitly, because getting it wrong is subtle and ugly:
the texture format is `R8G8B8A8_SRGB`, so the filter has to average in **linear**
light. Resampling the encoded bytes directly darkens every downscale. That is
why this uses the `_srgb` entry point and `STBIR_RGBA` (stb_image returns
straight, non-premultiplied alpha).

Cache identity had to grow with it: `UIImage.cacheKey` is now `path@size`, since
the same file decoded for a 48pt avatar and a 200pt hero are two different
textures that must not evict or alias each other. `UIImage.path` still names the
file.

For LavaSpotify: 300² → 140² is **4.6× fewer pixels** per cover, and it is what
lets covers into the atlas at all.

### P5. Every arriving image rebuilt the whole view tree **[fixed]**

`ImageStore.imageIfLoaded` raised `.body` on decode completion, and callers
branched structurally on its return —
`if let img = …imageIfLoaded(…) { Image(img) } else { placeholder }` — so the
*shape of the tree* depended on whether a decode had finished. Every arriving
cover therefore rebuilt everything.

Fixed with `Image(path:width:height:placeholder:)`: the leaf is the same leaf
either way and resolves its own texture at **emit**, so completion needs only
`.redraw`. Two things fall out of resolving at emit, both wanted — an arriving
image costs one redraw, and because the resolve runs *after* the cull test, only
images the frame actually draws are ever requested. Viewport-gated requests come
free from the draw-list cull instead of being the app's job, which is what issue
6's "request windowing belongs to the app" note had assumed was unavoidable.

Measured on the 1320-album library (6643 nodes) with `LAVA_IMAGE_BUDGET_KB=256`
to force constant eviction and re-decode, scrolling identically in both builds:

| | frames | body frames | body-frame time | worst frame |
| --- | ---: | ---: | ---: | ---: |
| `.body` (before) | 493 | **490** | 3220 ms | 155 ms |
| `.redraw` (after) | 30795 | **2** | ~0 | 4 ms |

The frame counts differ because the "before" build was too busy rebuilding to
service the scroll at all.

The *download* boundary still raises `.body`, and correctly: until the file
exists there is no path to hand the leaf, so that one really does change the
view.

### P6. The shape cache is flush-all

`Font.swift:235`: at 4096 entries the whole cache is dropped rather than
evicting a portion, so a UI holding more than 4096 distinct strings re-shapes
everything periodically. Not currently reachable in these three apps; noted so
it is not mistaken for an LRU later.

---

## Missing features

Ordered by how hard each is to add later.

| Gap | State | Notes |
| --- | --- | --- |
| **Accessibility** | Entirely absent | No AT-SPI, no semantic tree, no roles. Nothing here is reachable by a screen reader. `agentId` gives an automation tree with much of the needed shape, but it is a test hook, not an assistive-technology bridge. Largest single gap, most expensive to retrofit. |
| **IME / complex text input** | Absent | Only `glfwSetCharCallback` (`application.cpp:230`). No preedit, no candidate window — CJK input is impossible, and `TextField` documents itself as "Latin, no IME". |
| **HiDPI** | Manual only | Nothing queries `glfwGetWindowContentScale`. `FontStore.scale` exists and works, but the app opens at 1× on a 4K display until the user presses the zoom chord. |
| **Keyboard focus traversal** | Absent | `FocusManager` tracks a focused node but has no next/previous. No Tab navigation — a keyboard-only user cannot reach most controls. |
| **Multi-window** | Single-window by construction | `FocusManager`, `ViewInvalidation`, `ScrollRouter`, `CaretBlink` are all global statics; `ViewInvalidation` documents the assumption. |
| **Text selection outside the editor** | Absent | `Text` has no selection or copy. Selecting a track title or an error message is impossible; only `EditorView` supports it. |
| **Variable-height virtualization** | Fixed cell size only | `LazyVGrid`/`LazyVStack` exist (P1) but need a uniform stride. A virtualized list of wrapped log lines or chat bubbles still has no answer. |
| **Horizontal virtualization** | Absent | `LazyVGrid` is vertical-only. Home's shelves are horizontal `ScrollView`s and stay eager — fine at ~12 albums, not at 1000. |

---

## What to do next

Every performance item in this document is now closed. What remains:

1. **Variable-height virtualization**, when something needs it. The fixed-stride
   container covers every list these apps have; wrapped log lines would not fit
   it, and that is the next real design problem rather than a tuning exercise.
2. **Mipmaps** (P3), once something draws images well below their decode cap.
3. The feature table above, by need. Accessibility is the one that gets harder
   the longer it waits, because it constrains the node model itself.

Worth stating plainly: after this pass the framework's cost model is no longer
dominated by anything structural. A 1320-item library builds in 2.5ms, scrolls
in 1ms, and draws in 0.2ms. The remaining gaps are features, not scaling.
