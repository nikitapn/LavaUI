# What is broken when LavaUI runs as a client

Audited 2026-08-06 against `ArenaDemo host` + `LAVA_CLIENT=1 HelloWorld`,
release build. Everything below was either reproduced live or traced to the
line that makes it impossible; each entry says which.

The list exists because the client/server split is now good enough that what
is missing is no longer obvious from using it. Typing works, scrolling works,
images work — so the holes are the ones you find by reaching for something
three weeks later.

## Works, verified

Worth stating first, because it bounds the rest: mouse, wheel, hover, resize
and refresh all cross the wire; `Key` and `Text` both arrive, so a `TextField`
focuses, takes input and draws a caret; fonts and images register; surfaces
are created and torn down by `DestroySurface`; the in-window menu bar draws;
and a subtree keeps scrolling in the renderer while the client process is
stopped, which is the property the whole arena exists for.

## Broken

### 1. A dead client leaves its window on screen forever

**Reproduced.** `kill -9` the client: no `SurfaceNotFound`, no "surface
destroyed", no "subscription ended". The window stays mapped, nothing ever
draws into it again, and the compositor still counts it as a live surface.

The design says the input stream is the surface's lease — "this is the path a
crashed client takes". It is not: nothing on the shared-memory path notices
the peer's process died, so the stream never ends and the lease never
expires. Every other teardown route works, which is what hid this.

This is the one that has to be fixed before any of it is a desktop. It is
also the one Wayland answers for free — `wl_client` has a destroy signal —
so it may be worth fixing *there* rather than here.

### 2. Clipboard is dead

**Reproduced.** `xclip` something, focus the field, Ctrl+V: nothing.

By construction, and the construction is right as far as it goes —
`AppWindow::clipboardText` needs a GLFW window, a client has none, and
`LavaApp.openClient` deliberately leaves `ClipboardBridge` unwired rather
than pointing it at an engine that cannot answer. What is missing is the
other half: no `GetClipboard`/`SetClipboard` on the control plane, so a
client has no route to the display server's selection at all.

Copy *within* one client works — that is `TextEditing`'s own buffer, not the
system's.

### 3. File drag-and-drop is dead

`idl/lava.npidl` says so outright: `FileDrop`'s payload is a path list in a
side buffer that the next drop overwrites, so it does not fit the fixed-size
`InputEvent` and is the one event kind not forwarded.

The cost is larger than it sounds: `DropTarget.swift` / `DropRouter` is a
whole LavaUI feature, and it is unreachable in client mode. Needs a call of
its own (`TakeDroppedPaths(surfaceId)`), not a wider event.

### 4. A client cannot open a second window

`LavaClient` creates exactly one arena and one surface, and `LavaApp.openWindow`
is worse than unsupported — it is unguarded. It reaches
`Application::openWindow`, which builds a real `AppWindow` (a GLFW window, in
the *client* process) and then calls `bringUpWindow` → `device.textRenderer()`
on a device that was never initialised.

Traced, not run. The protocol is already fine with it — a surface per arena,
one input stream each, and the IDL says a client with two windows gets two
streams. The plumbing above it is what is absent, plus a `deviceUp` guard so
the wrong call fails instead of doing that.

### 5. Images have to be files on disk

Also stated in the IDL, and repeated here because it is the kind of
constraint that gets rediscovered by a feature: `RegisterImage` takes a path
the *renderer* opens. An image the client has only in memory — downloaded,
generated, decoded from a blob — cannot be registered. Cover art works today
because `SpotifyCore` writes it to a cache file first.

### 6. The agent cannot see a client's pixels

`AppWindow::capturePng` returns `false` with no renderer, so `screenshot` and
`screenshot_node` fail against a client. Everything else in the agent server
works, because it reads the layout tree rather than the framebuffer.

Compounded by the known one: **agent-injected clicks do not reach handlers on
a client that also has a compositor input stream** — the hit test finds the
node, the state change never lands. Both together mean the automation path
that the rest of this project is tested with does not work in the mode the
project is moving to.

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

Most of the "missing" list and half the "broken" list are things Wayland
already has an answer for — `wl_data_device` for both clipboard and drag and
drop, `wl_pointer.set_cursor`, `xdg_toplevel` for window state and for the
second window, `wl_client`'s destroy signal for the dead-client case. That is
an argument for not building them twice on `lava.Compositor` first.

What does *not* come from Wayland, and stays ours either way: the draw arena
and its retained scene tree, resource ids (`RegisterFont`/`RegisterImage`),
and the agent path. Those are the ones worth investing in on this interface.
