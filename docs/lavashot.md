# LavaShot — the screen, frozen, with something drawn on it

Run it and it photographs the desktop, then covers the desktop with the
photograph. Everything after that happens on a picture: drag a region, draw on
it, and press Enter to copy or Ctrl+S to save. The windows underneath are still
there and still running, and nothing the tool does touches them.

| Concern | Where |
|---|---|
| Selection geometry, the annotation document, the toolbar's layout | `Sources/LavaShotCore` (no engine, unit-tested) |
| The overlay, the drawing, the export | `Sources/LavaShotApp` |
| Compositing the screen, cropping it, holding the clipboard | `CaptureScreen`, `SetClipboardImageFile`, `SetFullscreen` |

## Taking the picture

The compositor already knew how to do this. `Server::renderOutputPng` builds
the whole scene into a swapchain buffer of its own and encodes it — it is what
Print Screen and the xdg-desktop-portal screenshot both run on — and it takes a
crop rectangle. `CaptureScreen` is that, plus two things a client cannot do for
itself.

**Leaving itself out.** By the time LavaShot can call anything, its own window
is up: it needs a surface to have a control-plane connection at all. So the
compositor takes the caller's own nodes off the scene for the length of one
offscreen composite — content, title bar, shadow and frost plate — and puts
back exactly what it took, from what was enabled rather than from the rules
that would decide it. This is the same trick the frost capture plays, for the
same reason.

**Cropping.** A LavaUI client has no codec, so a region of a PNG is not
something it can cut out for itself. The crop goes with the request.

## The path, not the bytes

`CaptureScreen` answers with a filename. A shared-memory reply is capped at
512 KiB and a screenful of PNG is 1.1 MB at 1280×720 — this was found by the
call hanging until the client's ten-second timeout, which is what an
over-length reply looks like from the outside.

Paths turn out to be better than bytes would have been. The compositor writes
the file; LavaShot hands the same path straight back to `registerImage`, and
the compositor decodes its own file into a texture. The pixels never cross the
boundary in either direction. The file belongs to the client from the moment
the call returns, and `ShotSession.discard` is what removes it — a tool that
leaves a screenful of PNG in `/tmp` every time it runs is a tool that fills a
disk.

## The export is a photograph of the window

Save and copy do not rasterise anything. The window is already showing the
finished result — the shot, the annotations, at 1:1 — and the only thing wrong
with it is the interface on top. So the export hides the interface, lets one
frame be drawn, and captures *that*:

1. A click or a key sets the pending job and asks for a redraw.
2. The paint that follows draws the picture and the marks and stops — no dim,
   no selection outline, no toolbar — then asks for one more frame.
3. The next paint runs when the clean frame has been presented, and captures
   the screen cropped to the selection, this time with `includeSelf: true`.

The two frames are the whole subtlety. A capture reads the window's *current*
buffer, so asking for one in the same frame that hid the toolbar photographs
the frame before it, toolbar and all.

The alternative — drawing the annotations a second time into a pixel buffer —
means writing a line renderer, an ellipse renderer and a glyph rasteriser in
the app, and having them disagree with the engine about what the user was
shown. Which is why the interface is painted by one `Canvas` rather than built
from widgets: taking all of it out of the picture is one `if`.

## What is missing

- **One output.** The shot is the screen the pointer is on. A selection cannot
  span two monitors.
- **No text tool.** Everything else on the bar draws; typing on a screenshot
  needs a caret, a field and an editing model over a picture, and it is the one
  tool that is a feature rather than a shape.
- **The selection cannot be adjusted.** Drag a new one instead. Handles are
  drawn but are not yet grabbable — `ShotRect.moved` is written and tested and
  has no caller.
- **No delay or window mode.** `LavaShot --delay 5`, and picking a single
  window rather than a region, are the two things a screenshot tool is usually
  asked for second.
- **Blur is a redaction, and is exactly as strong as it looks.** It is the
  engine's content blur at radius 18, captured as pixels — there is no
  recoverable original underneath — but it is not a guarantee about small text
  at large scale. Cover, then check.
