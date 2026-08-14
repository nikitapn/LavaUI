# The retained half of the draw list

A draw list is immediate: republished every frame, owned by nobody once
written. Its ceiling is that **nothing can move without the app**. Scroll,
hover, a caret blink, a drag — each costs a wake, a full re-emit and a round
trip. At one client that is invisible; on a desktop it is the difference
between a window that scrolls and a window that is frozen.

A *node* is a command with an identity, and the identity is what lets the
renderer keep state of its own against it. Scroll offset is the first such
state, and it is enough to demonstrate the property the whole idea exists
for: the renderer redraws without the app.

The wire format defaults to node-local coordinates. LavaUI sets
`SceneNodeAbsoluteCoordinates` because its existing draw-list emitter uses
window coordinates; in that mode the renderer adds retained translations and
scroll offsets but does not add the node's layout origin a second time.

## Shape

Two command kinds, not a separate node array:

    BeginNode   param = id, x/y = local offset, w/h = viewport,
                color = SceneNodeFlags
    EndNode     x/y = content extent, w/h = span actually emitted,
                color = hover tint, param = press tint
    NodeAnimate color = which properties, x/y = target translation,
                w = target opacity, aux = time constant

The command list already works this way — `PushClip`/`PopClip` and the blur
scopes are the same bracketing, and a node is those plus a name. A renderer
that ignored both kinds would draw exactly what it draws today, because a
node with no offset is transparent. It also means no change to the arena: no
fifth array, no new capacity field, no growth path to get right.

Content extent lives on `EndNode` rather than `BeginNode` because that is
where the producer knows it. How big a node's content turns out to be is a
*result* of emitting its children, not an input to it.

## Composition

`RenderWindow::replayDrawList` keeps a stack of open nodes and an accumulated
offset, and every position it emits goes through that offset.

Applying the transform as vertices are built — rather than rewriting the
command and glyph arrays into a translated copy — is what keeps the
shared-memory promise intact. Text is the reason it matters: a `Text` command
positions nothing itself, its glyphs carry absolute pen positions in the side
buffer, so translating "the command" would mean copying and rewriting the
glyph array, the largest of the four. Instead the offset is added at
`pushGlyph`. Nothing is copied, exactly as before.

Spatial triangles follow the same rule, once you notice they can. A
`SpatialVertex` is already projected — it carries window pixels and a depth,
the producer having done the projection — so the node's transform is a plain
translation of the result, and `pushSpatialTriangles` copies every vertex into
the buffer regardless. Applying the offset in that copy costs nothing. Only
x/y: `z` is the scene's own ordering, which moving a node across the screen
does not change. Clipping needed nothing at all, since the triangles already
take whatever scissor an enclosing node pushed.

This was skipped once, on the belief that those vertices were in the scene's
own space and a Scene3D inside a scroll view could only be half-moved. The
belief was wrong — the struct says window pixels — but the caution was sound
until LavaUI put a scene inside a scrolling node. `ScrollView` wraps arbitrary
content, so it does.

## Scroll

`sceneState_` on `RenderWindow` maps node id → offset and target, and is
deliberately *not* cleared when the producer republishes — surviving the
republish is the whole point. It is cleared when a window's producer changes,
because node ids are a producer's private numbering and offsets held against
the old one's ids would apply themselves to whatever reused an id.

A wheel event is offered to the scene graph before it is queued for the
client. If a scrollable node under the pointer moves, the event is consumed
and the client is never told: not woken, not waited for.

That leaves a repaint nobody asked for, which the frame loop has no way to
learn about — nothing was published and no input was queued. Hence a third
signal, `Editor.takeInternalRepaint(window:)`, alongside "a producer
published" and "input arrived".

## Who gets the wheel

Taking the wheel first is what makes scrolling survive a busy producer, and
it is also the one place the renderer can be confidently wrong. A pointer is
inside every container that encloses it, so "the node under the pointer" is
never one node — and picking the scrollable one means a code editor, a
zoomable camera or a chart nested in a `ScrollView` never sees a notch again.
The failure is quiet and asymmetric: the widget works fine whenever the
container around it happens to be at its end, and not otherwise.

The chain is walked from the inside out. A pane already at its limit passes
the notch outward rather than swallowing it, which is what makes a nested list
inside a page behave. A node flagged `kSceneNodeWheel` — LavaUI sets it for
anything registered with `ScrollRouter` — ends the walk *without* consuming,
because whether that widget will take this particular notch is a question only
the producer can answer.

So the deference has to be answered rather than assumed. The producer routes
the event through its own chain, and if nothing wants it, hands it back via
`scrollSceneUnclaimed`: the same walk minus the deference, now that the
question it was waiting on has been answered. Two crossings of the boundary,
but only for events over a widget that claimed the wheel — ordinary content
still never reaches the producer at all.

## Animation

A wheel notch moves the node's *target*; the visible offset eases toward it.
Applying a notch directly is what makes wheel scrolling feel like a stepper.

The curve is an exponential approach — the remaining distance falls by 1/e
every 75ms — rather than a fixed-duration tween, because notches land while
the last one is still in flight. A decay just keeps running against a moved
target; a tween would have to decide whether to restart, extend or blend.
It is stepped by elapsed time, not per call, so it is the same speed at any
frame rate, and it snaps below half a pixel because chasing the tail of an
exponential would repaint forever.

Measured settling after one burst: 464 → 473 → 477 → 479 → 480, then still.

An animation asks for the next frame itself: `stepSceneAnimations` sets the
repaint flag and posts an empty event, so the loop does not park mid-ease.
Once settled it does neither, and the window goes back to costing nothing —
about 0.8% of a core while idle, and the same again once a scroll is done.

## Read-back

Scrolling a node deliberately does not reach the producer, which is what lets
it work while the producer is stopped. But a producer that never learns where
its node ended up cannot virtualize a list — it has no idea which rows are on
screen — so the *decision* stays in the renderer and the *result* goes back,
as `InputEventKind::NodeScroll` on the existing input stream: `button` = node
id, `x`/`y` = offset.

No new channel, because the input stream already has credit-based flow
control and a coalescing queue. Coalesced per node id rather than against the
back of the queue: an animating scroll emits one per frame, and two nodes
animating at once would otherwise take turns failing to coalesce. A producer
that ignores the kind entirely is obliged to do nothing.

## Emitted span, and why a virtualized node needs one

`EndNode` carries two different facts: `x`/`y` is how far the node can
*eventually* scroll, and `w`/`h` is the span it actually drew this frame.
A producer that draws everything leaves the second at zero.

Without it, virtualization and "scrolls while the producer is stopped"
contradict each other — and visibly. A frozen producer cannot emit new rows,
so scrolling past the ones it did emit shows a blank panel. With it the
renderer clamps the *position* (never the target) to the drawn span: the
scroll runs to the last row that exists and stops there.

Two properties fall out. A node held at that edge reports settled rather than
animating, so it asks for no further frames — claiming to animate would spin
at the display rate against a producer that may never draw the next row. And
the target is kept, so the producer's next publish moves the bound and the
scroll picks up exactly where it left off.

Settling is a promise not to ask for frames, which makes the publish the only
thing that can resume the node — so the publish has to be *noticed*. The step
for a frame runs before the replay that delivers the new span, so a node would
otherwise be judged against the previous one, find itself already at the edge,
and stay there: a flick that stopped a third of the way with no reason
visible anywhere. `takeSceneResume` is that notice. It is set during replay,
where the rows arrive, and read after it.

## Overscan, and who decides how much

The span is a promise, so a producer that draws exactly one viewport can be
scrolled exactly nowhere before it has to be consulted again. Drawing beyond
the visible band is what buys the renderer room, and how much it draws is how
far a scroll travels while the producer is busy.

LavaUI states that budget once, in `ScrollNode.desiredSpan`, at half a
viewport each side. Two things read it: the cull, which decides what is
emitted, and `LazyVGrid`, which decides what is *mounted*. They used to
choose separately — the grid kept two rows of overscan for its own reasons —
and the smaller silently won, capping a half-viewport budget at sixty pixels
without anything reporting a conflict. One statement, two readers, is the
whole fix.

What is finally reported is `paintedSpan`: the budget narrowed to what is
really there, because a cell that was never mounted has nothing to draw at any
cull width. Reporting the budget rather than the paint would put the promise
back exactly where it started.

Measured: frozen at the edge, rows 131–140 on screen with the panel held at
y=4320 and the host at ~0.8% of a core. Resumed, it continued to y=5760 —
the target it had been holding all along.

## Hover and pressed

The most frequent state change in an interface, and pure geometry the
renderer already has. Recomputing it in the producer costs a round trip and a
whole re-emit per mouse move to reach an answer that was free over here.

The producer cannot pick the colour from another process, so it declares one:
`EndNode.color` is drawn over the node while the pointer is inside it, and
`EndNode.param` while it is also being pressed. Zero means none, so a node
that says nothing behaves exactly as before. They live on `EndNode` because
that is where they are *drawn* — an overlay goes on top of the subtree, and
the subtree ends there.

They fade rather than switch, on the same machinery the scroll uses. The two
constants are asymmetric on purpose: **55ms in, 120ms out**. A highlight that
fades in slowly reads as lag — the pointer is already there and the interface
has not agreed yet — while one that fades out quickly reads as a flicker when
the pointer crosses a list. Fast to acknowledge, unhurried to let go.

Press *cross-fades* with hover rather than stacking on it, since the press
tint is meant to replace the hover one: hover recedes by exactly as much as
press arrives. Guarded on the press tint existing, so a node that declares
only a hover tint does not dim itself when pressed. What is interpolated is
the tint's **alpha**, not a blend toward the background — a tint is an
overlay, so "half faded in" is the same colour at half the opacity, and that
stays true over whatever it happens to sit on.

Measured at one pixel inside a row: `#9B9B92` off, rising `9E → A3 → A5 →
A7 → A9` to `#AAAAA3` hovered, `AD → B1 → B4 → B6` to `#B9B9B4` pressed, and
back to exactly `#9B9B92` on the way out. It settles rather than creeping —
the step below one level of 8-bit alpha snaps, because continuing would ask
for frames that change nothing.

Three things about the semantics are deliberate:

- **A press is observed, not consumed.** A scroll is intercepted, because
  moving a subtree is a decision the renderer can make on its own. A press
  is not: it *means* something, and only the producer knows what. So the
  renderer paints the feedback and forwards the event unchanged.
- **The press belongs to the node it started in**, and draws only while the
  pointer is also still inside — which is what makes "drag off, release
  elsewhere" read as a cancel, and dragging back read as re-arming.
- **Hover is re-answered every repaint**, not only on motion. Content
  scrolling under a stationary pointer changes what is beneath it just as
  surely as moving the pointer does.

Nodes declaring no tint are skipped by the hit test unless they explicitly set
`SceneNodeHitTest`. LavaUI uses that flag for semantic `onHover` callbacks that
do not paint a tint. A scroll container sets neither: it is not a control, and
letting it swallow hover would stop the rows inside it from ever lighting up.

## Declared animation

Scroll and the tints animate because the renderer owns their targets. A
producer needs to be able to name one too, or every transition it wants costs
it a frame of its own attention for as long as the transition lasts.

`NodeAnimate`, placed inside a node, states where that node should end up:
a target opacity, a target translation, and optionally a time constant. The
producer says the destination and stops thinking about it. It emits identical
frames while the node is in flight — the two resting states are the only ones
it ever describes — and the renderer produces everything between.

One carve-out. **Opacity multiplies down the tree**, applied as each colour
is emitted, so a faded parent fades its children without any of them knowing
— spatial triangles included, per vertex, in the same copy that translates
them. **There is no scale.** A glyph quad's size comes from the atlas at a
fixed rasterization, so scaling text would mean re-rasterizing or an SDF
pipeline; scaling everything except the text would be worse than not scaling.

The first frame a node declares an animation, the property **snaps** rather
than easing. A node that has just appeared has nothing to have moved from,
and fading in every new node from nothing is not a default anyone asked for.
To animate an entrance, declare the start on one frame and the end on the
next.

Targets are retained like everything else about a node, so a frame that ran
out of arena before reaching the command leaves them alone. The cost of that
choice: a producer that *stops* declaring a property keeps its last target
rather than reverting.

Demonstrated by toggling the demo's chips with the space bar and stopping the
client 50ms in, far short of the landing. They arrive anyway — the last
frames of the motion composed from a stopped process's draw list — and the
window settles at 4 ticks of CPU over 6 seconds.

### Decay or duration

`kSceneAnimDuration` reads the time value as a duration instead of a decay
constant. The difference is not the feel, it is coordination: an exponential
approach never technically finishes, so two nodes easing with the same time
constant from different distances stop being visibly in motion at different
moments, and one gesture reads as several.

Measured on three chips travelling 70, 150 and 230px, sampling the left edge
of each while they return home:

    duration 0.5s     t2: 100 147 166    t3: 57 58 52    t4: 40 40 40
    decay    τ=0.16   t2:  64  84  97    t3: 51 61 68    t4: 45 50 53
                      t7:  40  41  41    t8: 40 40 41    t9: 39 39 40

Under the duration all three converge and land on one sample. Under the decay
the near chip settles two samples before the far one, after a long stretch
where all three are nearly home and visibly staggered.

Timed transitions interpolate from a recorded start rather than accumulating
per frame, so they cannot drift and they land on exactly the target rather
than approaching it. The start is stamped with the frame's own timestamp, not
read from the clock at the moment each node is visited, so every node
retargeted in one replay shares one start — which is the whole guarantee.

The curve is a symmetric cubic ease. Linear motion is the one curve that
always looks mechanical, and easing only the end looks like a stumble.

What it costs: a timed animation has to remember where it started, so
retargeting it mid-flight restarts the clock from the visible position rather
than simply bending toward the new target the way a decay does.

### Arrival

Declaring a target and then not thinking about it leaves the producer with no
idea when the node got there, and sequencing one transition after another is
the ordinary reason to care. `InputEventKind::NodeAnimationDone` closes that:
`button` = node id, one per transition, on the frame it lands. A timer in the
producer would be a second copy of the renderer's clock, running in a process
that may not be scheduled at the moment it matters.

An edge, not a state, which is what makes the details load-bearing:

- **Not coalesced**, unlike `NodeScroll`. A position is a state and only the
  newest matters; an arrival dropped is the thing it was for, gone.
- **Not sent for the first-frame snap**, because nothing moved.
- **Not sent when a producer restates a target it has already reached** —
  which it does on every frame, so this is the difference between one event
  and sixty a second. Verified by leaving the demo settled: the arrival
  counter reads 3/3 four seconds apart.

Timed transitions assign their end values rather than letting the
interpolation land on them. `start + (target - start) * 1` is the target only
up to rounding, and "has it arrived" is answered by comparing against the
target exactly — this was found the direct way, by the signal never firing.
In decay mode the equality holds by construction, since the snap below one
drawable step assigns the target.

The demo sequences a badge off it: three chips move, and only once all three
have reported does the badge animate in. Nothing in the producer knows how
long any of that took.

## Hover read-back and click routing

The renderer hit-tests to draw the tints, so it already knows which node is
under the pointer. `InputEventKind::NodeHover` says so: `button` = node id,
0 for none.

Without it the producer hit-tests the same geometry a second time from
coordinates — and gets it *wrong* for any node the renderer has scrolled or
animated, because that node is no longer where the producer declared it.
Wrong exactly when it matters, which is why this is not merely redundant.

A press needs no event of its own. The renderer presses whatever is hovered,
and the hover is queued immediately before the `MouseDown` that follows, so
"the node this click is for" is simply the last one reported. That pairing is
why the coalescing is against the back of the queue only: a run of hover
changes collapses, one separated by a `MouseDown` does not.

The demo routes row selection this way — click a row, scroll a thousand rows,
click again, and the right row is selected with no geometry computed on the
producer's side.

## Reclaiming node state

Node ids come from the producer, so `sceneState_` was append-only for the life
of a window: a virtualized list left an entry behind for every row ever
scrolled past, and nothing was ever freed. Individually small, but a
compositor is a process that runs for weeks.

State is now stamped with the replay it was last drawn in and swept in
batches, dropping anything absent for 1800 replays — about half a minute at a
display rate. Generous rather than prompt, because forgetting is visible: a
node that comes back inside the window keeps where it was scrolled to, and one
that comes back after it starts again from the top. The hovered and pressed
nodes are never swept, since they are live even on a frame that happened not
to draw them.

Verified by the thing that would break first: a panel scrolled to y=38400 and
left for 40 seconds — past the window — still held its position, because a
node that is drawn every frame is never absent.

## Robustness

The list is written by another process, so the composer treats a malformed
one as ordinary input rather than as an error:

- **Unbalanced `EndNode`** — ignored, rather than popping a stack that was
  never pushed.
- **Nodes still open at the end of the list** — closed, so the scissor stack
  is balanced whatever arrives. This is not hypothetical: a producer that
  runs out of arena mid-frame drops the commands that did not fit, and the
  one it drops may be an `EndNode`.
- **A frame whose `EndNode` went missing** — the content extent is retained
  per node, not re-read per frame, so a short frame is merely a short frame.
  Re-reading it per frame collapsed the extent to the viewport, which clamped
  the scroll back to the top; this was observed before it was fixed, as an
  occasional snap to row 0 during the arena's growth cycles.

## Demonstrated

The original retained-scene prototype used an animated bar chart (immediate)
beside a 5000-row panel inside one scrolling node (retained).

- Wheel over the panel: it scrolls, and the client's own counter stays at
  "0 scrolls seen here" — the events never reached it.
- Wheel outside the panel: the panel does not move and the counter climbs.
- `kill -STOP` the client: the frame counter freezes, the bars stop, and the
  panel still scrolls — up to the last row the client drew.
- Two clients: independent offsets, one at row 6 while the other is at 17.
- Scrolling past the end clamps at the last row rather than running off.
- The panel is virtualized against the read-back: 5000 rows declared, about
  eighteen emitted, three rows of overscan because the offset the producer
  is working from is a frame old.
- Every row is a node: it lights up under the pointer and brightens when
  pressed, with the producer told only that a click happened. The click
  still arrives — the counter increments — because a press is observed
  rather than consumed.
- Hover works with the client `kill -STOP`ped, at a frozen frame counter —
  fade included, and the fade settles there rather than spinning: 5 ticks of
  CPU over 6 seconds, the same as with the pointer outside the panel.
- Hover follows the content: with the pointer held still, one notch at a
  time moved the lit row 5 → 7 → 9.

## Not done

- **The tree is still republished every frame** — and measurement says leave
  it that way for now. A client that changes one label does rewrite its whole
  list, and that rewrite costs 0.08 ms; the same frame spends 9 ms in body and
  layout. `DrawList` culls as it walks, so what crosses the boundary is bounded
  by the viewport rather than by the tree: a 60-row list and a 560-row list
  both published 58 commands. Deltas against a persistent tree — versioning, a
  change log — would optimize the two cheapest stages in the pipeline. See
  "Where the frame actually goes" in [performance](performance.md) for the
  numbers and for what would change the answer.
- **No damage tracking.** A moved node repaints its whole window.
- **Hit-testing is used for scroll only.** The renderer knows the node
  geometry, so routing a click to a node id — rather than shipping
  coordinates and making the client hit-test — is available and not wired.
- **No scale, and no rotation.** See above: text is the obstacle, and a
  transform that silently skipped it would be worse than none.
- **Two curves, neither chosen.** Decay or timed cubic; there is no way to
  ask for a spring, an overshoot, or a different easing.
- ~~**Nothing in LavaUI emits any of this yet.**~~ Done. `ScrollView` opens a
  node, and whole LavaUI apps run as compositor clients through `LavaClient`.
  See "Wiring this to LavaUI" below.
- ~~**Node ids are the producer's to invent, and there is no scheme for it.**~~
  Done — `SceneNodeIdentity`. Dynamic trees get ids from there.
- **A tint is a flat overlay** over the node's whole viewport, text
  included. That is the ordinary highlight look at low alpha, but it cannot
  express "change this one background colour".
- **No fling.** A wheel notch is a discrete step, so this eases to a target
  rather than integrating a velocity. Kinetic scrolling from a touchpad
  would want the latter.
- **A client cannot name a resource it did not get from the renderer.**
  `GPUResourceHost` covers fonts and image files; an image the client holds
  only in memory has no way across. See `RegisterImage` in `idl/lava.npidl`.

## Wiring this to LavaUI

The wire format and the renderer are complete enough to build on, and the
in-process path goes through the same `replayDrawList`, so nodes work there
without any new plumbing. What is left is not plumbing:

1. ~~**Node identity.**~~ Done — `SceneNodeIdentity`. LavaUI already had the
   hard half: `NodeID` is the identity reconciliation preserves, so a keyed
   `ForEach` row keeps it across an insert above it. What was missing is a
   dense `uint32` alongside it, since `NodeID` is a counter that only climbs
   and truncating it would eventually wrap onto a live node.

   The difficulty is not minting ids, it is **reusing** them. An id released
   and immediately reissued hands the new node whatever the renderer still
   remembers about the old one — the symptom is a fresh list that opens
   already scrolled, and it appears only after a specific amount of churn. So
   an id waits out `retentionFrames` (matching the renderer's
   `kRetainReplays`) plus a quarantine before it can be handed out again, and
   the two constants are documented as a pair because changing one alone
   reintroduces the hazard.

   Counted in frames rather than seconds, because the renderer counts
   replays: an idle app is not drawing and its renderer is not replaying, and
   under a clock the two would disagree about how long "a while" is.
2. **Deciding who owns each behaviour.** LavaUI already implements scroll,
   hover and pressed in Swift. Wiring the renderer's versions in means
   deleting the Swift ones, not running both — two systems with an opinion
   about a scroll offset is a bug farm. This is the actual work, and it is
   design work.
3. **Layout that reads scroll.** Cull rects and any virtualization currently
   take the scroll offset from LavaUI's own state. They would have to take
   it from `NodeScroll`, which is a frame behind — the demo covers that with
   overscan, and LavaUI would need the same.
4. **A place for tints to come from.** `EndNode` takes two colours; LavaUI
   has themed hover and pressed states already, so this is mapping rather
   than invention.

(2), (3) and (4) are done: `ScrollView` and the hover/press tints are the
renderer's, `paintedSpan` reports what was drawn so layout and the renderer
agree about a virtualized node, and `EndNode`'s colours come from the theme.

What is left is the thing none of it was blocked on — the tree is still
republished in full every frame. See "Not done".

## What is *not* retained

Worth stating because the name invites the assumption: **no draw commands are
cached**. Every frame still walks the whole command list and rebuilds every
vertex. What is retained is *state* — scroll offsets, tint fades, animation
targets — and what that buys is that the producer no longer has to be
scheduled for any of it.

Keeping vertex buffers per node and rebuilding only dirty subtrees is a real
further step, and node identity is exactly what it would need. It has not been
taken, and the measurement above is why: rebuilding *every* vertex of a
full-screen frame is 0.12 ms, so there is not much there to save. If a renderer
driving many surfaces turns out not to stay flat, threading it — one `VkQueue`
per thread — scales with the number of windows, which is the dimension that
would actually be growing.
