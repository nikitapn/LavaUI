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

## Shape

Two command kinds, not a separate node array:

    BeginNode   param = id, x/y = local offset, w/h = viewport,
                color = SceneNodeFlags
    EndNode     x/y = content extent, w/h = span actually emitted,
                color = hover tint, param = press tint

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

Spatial triangles are the one exception: a `SpatialVertex` is in the scene's
own space rather than in window pixels, so a Scene3D inside a scrolling node
is not supported. Its viewport moves; its geometry does not. Half-moving it
would be worse than not moving it.

## Scroll

`sceneState_` on `RenderWindow` maps node id → offset and target, and is
deliberately *not* cleared when the producer republishes — surviving the
republish is the whole point. It is cleared when a window's producer changes,
because node ids are a producer's private numbering and offsets held against
the old one's ids would apply themselves to whatever reused an id.

A wheel event is offered to the scene graph before it is queued for the
client. If the innermost scrollable node under the pointer moves, the event
is consumed and the client is never told: not woken, not waited for.

That leaves a repaint nobody asked for, which the frame loop has no way to
learn about — nothing was published and no input was queued. Hence a third
signal, `Editor.takeInternalRepaint(window:)`, alongside "a producer
published" and "input arrived".

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

Nodes declaring no tint are skipped by the hit test rather than hovered. A
scroll container is not a control, and letting it swallow the hover would
stop the rows inside it from ever lighting up.

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

`ArenaDemo produce <name>` draws an animated bar chart (immediate) beside a
5000-row panel inside one scrolling node (retained).

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
- Hover works with the client `kill -STOP`ped, at a frozen frame counter.
- Hover follows the content: with the pointer held still, one notch at a
  time moved the lit row 5 → 7 → 9.

## Not done

- **The tree is still republished every frame.** The renderer re-composes the
  last published frame with a new offset, which is what makes scrolling
  work while the client is stopped — but a client that changes one label
  still rewrites its whole list. Deltas against a persistent tree are the
  next step and a much larger one: it means versioning and a change log
  rather than a triple-buffered slot.
- **No damage tracking.** A moved node repaints its whole window.
- **Hit-testing is used for scroll only.** The renderer knows the node
  geometry, so routing a click to a node id — rather than shipping
  coordinates and making the client hit-test — is available and not wired.
- **Only scroll animates.** The machinery is general — a target, a decay, a
  self-requesting repaint — but only scroll declares one. Hover and pressed
  tints snap rather than fading, and opacity and transform transitions have
  no way to be declared at all.
- **A tint is a flat overlay** over the node's whole viewport, text
  included. That is the ordinary highlight look at low alpha, but it cannot
  express "change this one background colour".
- **No fling.** A wheel notch is a discrete step, so this eases to a target
  rather than integrating a velocity. Kinetic scrolling from a touchpad
  would want the latter.
- `DrawList.beginNode`/`endNode` exist for the in-process path but nothing
  in LavaUI emits them yet; its scroll views still do their own work in
  Swift.
