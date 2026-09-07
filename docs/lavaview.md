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

## Known limitations today

- **EXIF orientation is ignored**, so a phone photograph tagged sideways opens
  sideways. See below; this is a bug wearing a feature's clothes.
- **Animated GIFs show frame one.** `stbi_load` decodes the first frame and
  stops.
- **Decode is capped at 8192px on the long edge** (`ViewerSession
  .displayDecodeSide`), because `maxImageDimension2D` is only guaranteed to
  4096 and a panorama that fails to upload shows nothing at all. Past that,
  `1:1` is 100% of what is held rather than of what is on disk, and the status
  bar marks the size with `~`. Saving is unaffected — it re-decodes at native
  size.

## Next, in the order I would do them

### 1. EXIF orientation — correctness, not a feature

A photograph off a phone carries its orientation as a tag rather than in its
pixels, and roughly every phone writes one. Ignoring it means the single most
common source of images on the machine opens wrong, and the user "fixes" it
with the rotate button — writing a re-encoded file to correct something that
was never wrong.

Cheap, because the hard half exists: `Rotation` and `PixelRotate` already turn
pixels, and orientations 1/3/6/8 are exactly the quarter turns they implement.
What is missing is a reader — stb parses no metadata at all. A JPEG APP1
segment is a TIFF header and a tag list; the orientation tag alone is well under
a hundred lines of pure Swift, belongs in `LavaViewCore`, and is testable
against a handful of recorded headers with no GPU and no files.

Two decisions to make deliberately, not by accident:

- The turn is **display-only** until saved, exactly like a manual rotate. A
  viewer that silently rewrites every photograph it opens is malware with good
  intentions.
- Orientations 2/4/5/7 are mirrored, which `PixelRotate` cannot express. Either
  add a flip or refuse them; refusing is honest and they are vanishingly rare.

### 2. EXIF panel

The same parser, more tags: camera, lens, exposure, aperture, ISO, focal
length, when it was taken. A side panel toggled by `I`, or the bar growing a
second row — not a dialog, and not a mode.

The trap is scope: EXIF has hundreds of tags and a maker-note swamp, and the
answer is a fixed list of the dozen anybody reads. GPS is the one judgement
call — showing coordinates is useful, resolving them to a place name is a
network request an image viewer should not be making.

### 3. Resize and save

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

### 4. Animated GIF

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

Worth being honest that this is the largest of the four and the one a viewer
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
