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

## Labels are the one tool with a mode

`T`, then click, then type. Enter finishes the label and Escape discards it;
clicking anywhere else, picking another tool, or exporting all finish it too,
because that is what clicking away means everywhere else.

Nothing rasterises a glyph. `DrawList.text` draws the label through the same
engine as everything else, and the export photographs the window — so the file
gets the text for the same reason it gets the arrows. That is the whole reason
this tool was cheap to add and would have been a project on its own if the
export rasterised its own pixels.

Two things about it are load-bearing:

- **The keyboard belongs to the label while one is open.** `r`, `e`, `a`, `p`,
  `h`, `b`, `t` and `v` pick tools the rest of the time, and a screenshot tool
  that switched to the arrow halfway through the word "arrow" would be
  unusable. `ShotSession.editKey` runs ahead of the shortcuts and takes what it
  wants; Escape is the one key it hands back, so a first press closes the label
  and a second leaves LavaShot.
- **The caret is an index into characters, not bytes.** One backspace deletes
  one thing somebody typed, whatever it costs to store — `café` and a flag
  emoji are in the tests for exactly this.

The label is committed before any export, so a half-typed one is in the file
and the caret under it is not.

A label has no newlines: Enter is the commit gesture, and a two-line label is a
paragraph nobody asked for. It carries a dark plate behind it, always — a
screenshot is an arbitrary picture, red text on a red button cannot be read,
and a label that cannot be read is worse than no label.

## What is missing

- **One output.** The shot is the screen the pointer is on. A selection cannot
  span two monitors.
- **The selection cannot be adjusted.** Drag a new one instead. Handles are
  drawn but are not yet grabbable — `ShotRect.moved` is written and tested and
  has no caller.
- **A committed annotation has no identity** — nothing can be selected, moved
  or reopened afterwards; undo and redraw. This is deliberate rather than
  missing, and it is what Flameshot does too: a mark is made in one gesture,
  and giving every mark a handle to grab turns a screenshot tool into a
  drawing program.
- **No delay or window mode.** `LavaShot --delay 5`, and picking a single
  window rather than a region, are the two things a screenshot tool is usually
  asked for second.
- **Blur is a redaction, and is exactly as strong as it looks.** It is the
  engine's content blur at radius 18, captured as pixels — there is no
  recoverable original underneath — but it is not a guarantee about small text
  at large scale. Cover, then check.
