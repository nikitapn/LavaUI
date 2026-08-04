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
    EndNode     x/y = content extent

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

`sceneState_` on `RenderWindow` maps node id → offset, and is deliberately
*not* cleared when the producer republishes — surviving the republish is the
whole point. It is cleared when a window's producer changes, because node ids
are a producer's private numbering and offsets held against the old one's ids
would apply themselves to whatever reused an id.

A wheel event is offered to the scene graph before it is queued for the
client. If the innermost scrollable node under the pointer moves, the event
is consumed and the client is never told: not woken, not waited for.

That leaves a repaint nobody asked for, which the frame loop has no way to
learn about — nothing was published and no input was queued. Hence a third
signal, `Editor.takeInternalRepaint(window:)`, alongside "a producer
published" and "input arrived".

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
40-row panel inside one scrolling node (retained).

- Wheel over the panel: it scrolls, and the client's own counter stays at
  "0 scrolls seen here" — the events never reached it.
- Wheel outside the panel: the panel does not move and the counter climbs.
- `kill -STOP` the client: the frame counter freezes, the bars stop, and the
  panel still scrolls.
- Two clients: independent offsets, one at row 6 while the other is at 17.
- Scrolling past the end clamps at the last row rather than running off.

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
- **No renderer-driven animation.** `takeInternalRepaint` is the seam it
  would use.
- `DrawList.beginNode`/`endNode` exist for the in-process path but nothing
  in LavaUI emits them yet; its scroll views still do their own work in
  Swift.
