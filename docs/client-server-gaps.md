# What is broken when LavaUI runs as a client

Audited 2026-08-06 against `ArenaDemo host` + `LAVA_CLIENT=1 HelloWorld`,
release build. Everything below was either reproduced live or traced to the
line that makes it impossible; each entry says which.

The list exists because the client/server split is now good enough that what
is missing is no longer obvious from using it. Typing works, scrolling works,
images work — so the holes are the ones you find by reaching for something
three weeks later.

**Status, same day.** All six are closed or reduced: the dead-client case by
nprpc's new shared-memory liveness detection, the other five here. What is
left is a feature rather than a break (a client's *second* window) and one
known bug (agent-injected clicks on a client with an input stream). Each
entry keeps its original description under **Was:** — the point of the list
is what the shape of the thing was, not just that it is gone.

## Works, verified

Worth stating first, because it bounds the rest: mouse, wheel, hover, resize
and refresh all cross the wire; `Key` and `Text` both arrive, so a `TextField`
focuses, takes input and draws a caret; fonts and images register; surfaces
are created and torn down by `DestroySurface`; the in-window menu bar draws;
and a subtree keeps scrolling in the renderer while the client process is
stopped, which is the property the whole arena exists for.

## Broken

Numbering is kept stable as entries are fixed, so that a reference to "gap 4"
does not shift under it.

### 1. ~~A dead client leaves its window on screen forever~~ — fixed

**Was:** `kill -9` the client and nothing happened. No "subscription ended",
no "surface destroyed". The window stayed mapped, nothing ever drew into it
again, and the compositor still counted it as a live surface.

The compositor's half was already right — `SubscribeInput` ends by calling
`SurfaceRegistry.destroy`, on the theory that the input stream is the
surface's lease. What was missing was underneath it: a shared-memory peer has
no connection that breaks when it dies, so the stream never ended and the
lease never expired.

**Fixed in nprpc** by `8144258` and `c92c6ff` (2026-08-06), which give the
shared-memory transport what a socket gets for free: a `writer_detached` flag
in the ring header for a peer that disconnects politely, and a probed
`ProcessIdentity` (pid plus a start-time token, so a recycled pid is not
mistaken for the peer) for one that does not. The server session polls it and
cancels the session's streams the way a WebSocket close does.

**Re-verified 2026-08-06** after rebuilding: `kill -9` on the client now
walks the whole chain in about a second —

```
SharedMemoryChannel read thread exiting
SubscribeInput(surface 1) — subscription 1 ended
surface 1 (LavaUI · DemoExample) destroyed
Cleaned up ring buffers: /nprpc_…_s2c, /nprpc_…_c2s
```

— the client's window disappears from the X server, and the compositor stays
up. The ring segments are unlinked too, which was a second leak: before the
fix, a run left both 16 MB rings in `/dev/shm` forever.

### 2. ~~Clipboard is dead~~ — fixed

**Was:** `xclip` something, focus the field, Ctrl+V, nothing. Copy *within*
one client worked, because that is `TextEditing`'s own buffer rather than the
system's.

Half of it was already right: `AppWindow::clipboardText` needs a GLFW window,
a client has none, and `LavaApp.openClient` deliberately left
`ClipboardBridge` unwired rather than pointing it at an engine that could not
answer. The missing half was a route — nothing on the control plane could
reach the display server's selection.

**Fixed:** `GetClipboard`/`SetClipboard`, addressed by surface, with
`LavaClient.run` installing the `ClipboardBridge` pair once it has a surface
to name. Both block the client's frame loop for a round trip, from a key
handler — a keystroke's worth of latency in the client that pressed the key,
which is why the IDL says not to call them per frame.

Addressed by surface although neither call needs it to work. "May this client
read the selection" has to be answerable and the answer depends on which
window is focused; X11 lets anyone read at any time and Wayland deliberately
does not, and this signature can become the second without changing. Today
`requireSurface` only proves the surface exists.

**Verified:** `xclip` → Ctrl+V puts the text in a client's field; Ctrl+A,
Ctrl+C in the client puts the field's text back on the X clipboard.

### 3. ~~File drag-and-drop is dead~~ — fixed

**Was:** the `FileDrop` event crossed, but its payload did not — a path list
does not fit a fixed-size `InputEvent`. The cost was larger than it sounds:
`DropTarget.swift` / `DropRouter` is a whole LavaUI feature, unreachable
under a compositor.

**Fixed:** `TakeDroppedPaths(surfaceId)`, plus `DropBridge` in LavaUI to
reach it. It stays two things on purpose — the event says a drop happened and
*where*, which is what picks the view; the call says what was in it. Most
events are not drops and should not pay for the one that is.

The compositor copies GLFW's buffer the instant it polls the event, because
that buffer holds one drop and the next overwrites it. What it copies into is
a queue rather than a slot, so two quick drops are two drops; bounded at 16,
so a client that never collects cannot grow the compositor.

**Verified with a caveat worth stating.** XDND is not scriptable — a drag
between two X clients is a protocol conversation no injected event can start
— so the test synthesizes the drop through `LAVA_TEST_DROP`. That stands in
for exactly one thing: the call to `editor.droppedFiles`. The queue, the RPC,
the bridge, the router and the handler are all the shipping path. Two files
dropped on the target arrive as `dropped 2: alpha.txt, beta.pdf`; a drop
aimed at empty space reaches no handler.

### 4. A client cannot open a second window — still open, but no longer a crash

`LavaClient` creates exactly one arena and one surface, and `LavaApp.openWindow`
*was* worse than unsupported — it was unguarded. It reached
`Application::openWindow`, which builds a real `AppWindow` (a GLFW window, in
the *client* process) and then calls `bringUpWindow` → `device.textRenderer()`
on a device that was never initialised.

**Half-fixed:** `Application::openWindow` now checks `deviceUp` and returns 0,
which is what a failed open already meant, so no caller grows a case.

The feature is still missing, and the protocol is already fine with it — a
surface per arena, one input stream each, and the IDL says a client with two
windows gets two streams. What is absent is the plumbing above: `LavaClient`
would have to create a second arena, ask for a second surface, and route a
second input stream into the right `WindowScope`.

### 5. ~~Images have to be files on disk~~ — fixed

**Was:** `RegisterImage` takes a path the *renderer* opens, so an image the
client had only in memory — downloaded, generated, decoded from a blob —
could not be registered at all. Cover art works today because `SpotifyCore`
writes it to a cache file first.

**Fixed:** `RegisterImageData`, taking encoded bytes (PNG, JPEG, …) rather
than raw pixels — a 300×300 cover is ~30 KB as JPEG and 360 KB as RGBA, and
the renderer already owns the codec, which is most of what "a client needs no
GPU" was already promising.

Identity is a hash of the content, not a key the caller picks. Two clients
that both call their icon "logo" must not be handed each other's texture, and
the renderer cannot check a claim about a namespace it does not own — but it
can check the bytes. `ImageStore.contentKey` is the single implementation:
both sides derive it independently and nothing sends it across, so a second
implementation would silently become a cache miss on one side and a leak on
the other.

A path should still go through `RegisterImage`. This one copies the file
through the ring buffer; a path sends a path.

**Verified:** the ArenaDemo client builds a BMP in memory and gets it on
screen (`RegisterImageData(27702 bytes) → 96×96`); a second client generating
byte-identical pixels gets the existing texture with no second decode.

### 6. ~~The agent cannot see a client's pixels~~ — fixed

**Was:** `AppWindow::capturePng` returns `false` with no renderer, so
`screenshot` and `screenshot_node` failed against a client. Everything else
in the agent server worked, because it reads the layout tree rather than the
framebuffer — which is precisely why this one mattered: it was the only
command that checks what the user would actually *see*.

**Fixed:** `CaptureSurface` on the control plane, and `ScreenshotBridge` in
LavaUI — the third seam of the same shape as `ClipboardBridge` and
`DropBridge`, and unset means windowed, so an ordinary app installs nothing.

Bytes on the wire, base64 in the client. The agent's protocol is JSON and
wants text, but that is the client's protocol: encoding in the compositor
would put a third more bytes on the wire in service of something the renderer
does not speak.

**Verified:** `screenshot` against a client returns a real 400×311 PNG of the
compositor's framebuffer, and the windowed path still captures through the
same bridge.

**Still open, and the reason this one is not finished:** agent-injected
clicks do not reach handlers on a client that also has a compositor input
stream — the hit test finds the node, the state change never lands. The agent
can now *see* a client; it still cannot fully drive one.

## Missing rather than broken

No cursor shapes anywhere — no I-beam over a text field, no resize arrows.
This is not a client/server gap (windowed mode has none either), but a
desktop needs it and the client path is where it has to be designed, since
the renderer owns the pointer.

No global/panel menu for clients: `x11WindowId()` returns 0 without a window,
so `appMenuAttach` cannot register, and the menu bar degrades to in-window.
Correct fallback; still means a client cannot put a menu in a panel.

No monitor DPI. `ContentScale` is LavaUI's own zoom, not the display's scale
factor, and nothing carries the latter across.

No window-state protocol at all: minimize, maximize, fullscreen, retitle,
raise, request-focus, ask-to-be-resized. A client can be told its size and
can give the surface back, and that is the whole vocabulary.

## Against the wlroots plan

The original argument was that Wayland already answers most of this —
`wl_data_device` for clipboard and drag-and-drop, `wl_pointer.set_cursor`,
`xdg_toplevel` for window state and the second window — so building it twice
on `lava.Compositor` first would be waste. That argument still holds for what
is left in "missing rather than broken", and it is why the second window is
not being plumbed here.

It did not hold for what was *broken*, and the reason is worth keeping. Every
one of those five was a hole below the window protocol rather than in it: the
selection is a display-server resource whichever protocol names it, a drop's
payload has to reach a process that does not own the pointer either way, an
image with no path has no path under Wayland either, and a client with no
framebuffer is exactly as invisible to the agent. A wlroots compositor
speaking to LavaUI clients over shared memory would have inherited all of
them. The dead-client case makes the point most sharply: `wl_client`'s
destroy signal would not have helped, because the thing that failed to notice
was the transport, not the window.

So the split is not "wait for Wayland" versus "build it now" — it is whether
a gap is about *windows*, which Wayland owns, or about the client/renderer
boundary underneath, which stays ours no matter what protocol sits on top.

What does *not* come from Wayland, and stays ours either way: the draw arena
and its retained scene tree, resource ids (`RegisterFont`/`RegisterImage`/
`RegisterImageData`), and the agent path. Those are the ones worth investing
in on this interface.
