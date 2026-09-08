# LavaView — what it does, and what is worth adding next

LavaView is the desktop's image viewer: fit or original size, the wheel zooming
towards the pointer, the arrows walking the folder, and two rotate buttons that
can write the turn back to the file.

The bar along the top says what is open — window buttons, filename, an unsaved
turn, the pixel size, the position in the folder. The buttons sit centred along
the bottom and are all fixed-width, which is the whole reason the two are
separate: labels change width with every picture, buttons must not move at all,
and while they shared a row stepping through a folder slid the buttons out from
under the pointer.

| Concern | Where |
|---|---|
| Folder order, viewport arithmetic, rotation, save format | `Sources/LavaViewCore` (no engine, unit-tested) |
| Window, control bar, keyboard, save flow | `Sources/LavaViewApp` |
| JPEG encoder for writing a turned photo back | `canvas::encodeRgbaJpeg`, `Editor.encodeJpeg` |

## The rule for what gets in

The thing that made the discontinued Windows viewer good was that it opened
instantly and had exactly the controls you needed on one row. Every item below
is measured against that: **it earns a place only if it needs no mode, no
second window, and no reading.** An editor is a different application, and the
moment this one grows a toolbar with tools on it, it has become that
application badly.

Two consequences worth stating in advance. Anything that *writes* goes through
the existing path — decode the original at native size, transform, encode, write
beside and rename over — never through the display copy, which is capped. And
anything destructive asks first, in a bar under the title, the way the
overwrite confirmation already does.

## Walking the folder without a flash

Two things keep stepping through a folder from strobing, and both are load-
bearing rather than polish:

- **The neighbours are decoded ahead**, from `ViewerSession.adopt` — the moment
  a picture lands, not the moment one is asked for, which is a frame too early
  to know whether it landed. Only when the picture and both its neighbours fit
  in `ImageStore.budgetBytes` together, or the read-ahead evicts the picture on
  screen to make room for one nobody is looking at yet. The app raises that
  budget at start-up: the default is sized for many small images, and one
  24-megapixel photograph is 96 MB.
- **The outgoing picture stays up** until the incoming one is decoded
  (`ViewerSession.awaiting`). Nothing is cleared at the step — texture, size,
  zoom and offset all still describe what is on screen — and `adopt` swaps the
  lot in one go, so no frame is ever half of one picture and half of another.
  After a moment's grace a chip says which file is still coming; a step that
  hits the read-ahead never shows it.

The wait ends on a decode landing on a worker, which is not an event the loop
wakes for by itself, so the canvas asks for the frame that will notice
(`FrameScheduler.requestRedraw`). That same frame is what eventually calls a
file unreadable: `ImageStore.imageIfLoaded` answers nil both while a decode is
running and after one came back empty, and `ImageStore.isLoading` is what tells
those apart. Not on the first empty answer, though — the cache also evicts, and
an image that decoded and was then evicted looks identical from here.

## Known limitations today

- **Saving drops every other tag.** The JPEG encoder writes no metadata at
  all, so a photograph that is rotated and saved comes back without its camera,
  lens, date or coordinates. That is also why the orientation tag needs no
  clearing — there is no tag in the output to disagree with the pixels — but it
  is a real loss and the reason a rotate asks before it overwrites.
- **Animated GIFs show frame one.** `stbi_load` decodes the first frame and
  stops.
- **Decode is capped at 8192px on the long edge** (`ViewerSession
  .displayDecodeSide`), because `maxImageDimension2D` is only guaranteed to
  4096 and a panorama that fails to upload shows nothing at all. Past that,
  `1:1` is 100% of what is held rather than of what is on disk, and the status
  bar marks the size with `~`. Saving is unaffected — it re-decodes at native
  size.

## Turning a picture, and where it happens

A photograph off a phone carries which way up it is as a tag rather than in its
pixels, and roughly every phone writes one. Ignoring it meant the most common
source of images on the machine opened sideways, and the user "fixed" it with
the rotate button — re-encoding a file to correct something that was never
wrong.

It is fixed in the **decoder** (`canvas/src/render/exif.{hpp,cpp}`, applied in
`Engine::decodeImage` and `TextureManager::loadTexture`), not here, and that
placement is the whole design. The roadmap that planned this had it in
`LavaViewCore` with `PixelRotate` doing the turn, which would have worked
windowed and been unusable as a compositor client: the app has no GPU there, so
a turned picture reaches the screen by being PNG-encoded, sent through shared
memory and decoded again — seconds of that per photograph, and a second copy of
every picture held in the app besides. Decoding is already the compositor's
job, and a decoder that ignores the file's own orientation is not missing a
feature, it is returning the wrong pixels.

What that buys, beyond speed: the app needs no code at all. The read-ahead, the
cache budget and the byte accounting all go on describing the picture that is
actually shown; `1:1` and the pixel size in the bar are the picture's, not the
sensor's; and every other app that loads a JPEG got the same fix for free. All
eight orientations are handled, including the four mirrored ones that a quarter
turn cannot express — a gather loop does not care which of the eight it is
walking, so refusing them, as the plan had it, would have been more code than
supporting them.

Once that was true of the file's own turn, it was indefensible for the user's.
The rotate buttons had exactly the pipeline described above as unusable — a
local decode, a turn in Swift, a PNG of the result through shared memory, and
the compositor decoding it a second time — so the same quarter turn was free
when the file asked for it and cost seconds when a person did. `RegisterImage`
takes an `ImageTurn` now, and `GPUResourceHost.registerImage(path:maxPixelSize:
turn:)` is what the viewer asks: the client sends a path and a direction, and
the picture is turned on the side that was going to decode it anyway. In a
window the same call decodes on a worker and uploads on the main thread, which
is what that host was always for.

That leaves one implementation of turning pixels in the whole system, and the
save path uses it too — `Editor.decodeImage(path:maxPixelSize:turn:)` at native
size. `PixelRotate` is gone, and its absence is the point: a viewer with two
rotate implementations, one drawing the screen and one writing the file, is
wrong in the way nobody notices until the file is already saved.

The turn stays **display-only**: nothing writes the file until the user asks.
Saving bakes the total — the file's own turn and the user's — into the pixels,
and the output carries no EXIF at all, so nothing downstream turns it a second
time.

## Next, in the order I would do them

### 1. EXIF panel

Camera, lens, exposure, aperture, ISO, focal length, when it was taken. A side
panel toggled by `I`, or the bar growing a second row — not a dialog, and not a
mode.

The IFD walk in `canvas/src/render/exif.cpp` is most of a reader already, but
this one belongs on *this* side of the line rather than in the decoder: an
orientation changes the pixels a decoder must return, and a lens name does not.
It is a reader in `LavaViewCore`, tested the way the roadmap originally
described — pure Swift, recorded headers, no GPU and no files.

The trap is scope: EXIF has hundreds of tags and a maker-note swamp, and the
answer is a fixed list of the dozen anybody reads. GPS is the one judgement
call — showing coordinates is useful, resolving them to a place name is a
network request an image viewer should not be making.

### 2. Resize and save

The cheapest of the three obvious ones, because the write path is already
built: decode native, transform, encode, atomic rename, with `SaveTarget`
already deciding format and lossiness and already asking before it overwrites.
Resize is one more transform in the middle, and `stbir_resize_uint8_srgb` is
already linked and already used by `finishDecode` and by `encodeRgbaPng`'s
`maxSide`. What is missing is an entry point that takes an arbitrary
destination size rather than a long-edge cap.

Keep the interface to a percentage and a long edge, with the aspect locked. The
moment it grows independent width and height, a stretch checkbox and a
resampling-filter menu, it is a dialog and this is a different program.

**Crop** is the natural sibling and shares the whole pipeline; the `Canvas`
already reports drag gestures, so the missing part is a rubber-band rectangle
and the arithmetic to map it back to source pixels — which belongs in
`LavaViewCore` next to `ViewportMath`, for the same reason that is there.

### 3. Animated GIF

No new dependency: `stbi_load_gif_from_memory` returns every frame and a delay
array in one call. The work is that the pipeline assumes one texture per path,
so it needs a multi-frame decode on `Engine`, somewhere to keep N textures, and
a clock — and `FrameScheduler.requestRedraw(in:)` is the right one to pace it
with, because the deadline *is* the event (see AGENTS.md: `requestWake` alone
buys an iteration that does no work).

The real design question is client mode. Frames would go over `RegisterImage`
one at a time, so a hundred-frame GIF is a hundred round trips and a hundred
textures resident. Options, in the order I would consider them: cap total
decoded pixels and fall back to frame one past it; or add a call that registers
a whole strip at once. The second is an IDL change — method indices are
positional, so both stubs regenerate together.

Worth being honest that this is the largest of the three and the one a viewer
can most defensibly not have.

## Cheap things that punch above their cost

- **Set as wallpaper.** The one thing a generic viewer cannot do and this one
  nearly can already: `SetWallpaper` is in the IDL and `DesktopSettings
  .setWallpaper` is in `LavaClient`. A menu item and an error path.
- **Fullscreen** (`F11`), and a slideshow timer on top of it. The folder cycle
  and the fit maths already exist; this is a window state and a `requestRedraw`
  deadline.
- **Copy to clipboard.** The compositor already has `Clipboard::setImagePng`,
  but the control plane only exposes `GetClipboardPng` — a client can read an
  image and not write one. Needs `SetClipboardPng` appended to the interface.
- **Move to trash**, never delete. The old Windows viewer put a delete button
  one pixel from Next, which is why this one has neither. The freedesktop trash
  spec is a move plus a `.trashinfo` file, and it is undoable — which is the
  only reason it is allowed on the bar at all.

## Deliberately not planned

- **Editing beyond a turn, a crop and a resize.** Levels, filters, red-eye. A
  viewer that grows these becomes a bad editor and stops being a fast viewer.
- **A thumbnail browser.** That is a file manager. The folder is already a
  cycle, which is the viewer-shaped answer to the same need.
- **Network sources.** An image viewer that waits on a socket is not one.
