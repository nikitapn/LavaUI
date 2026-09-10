# What the desktop still lacks, and what each thing actually costs

Assessed 2026-09-08 against the tree at `2316353`. The question behind it is a
fair one: Lava has become a desktop environment more or less by accident, one
app at a time, and the list of what a person expects from a desktop is now
shorter than the list of what is here. This is that remaining list, with an
estimate attached to each — because two of the six things that look missing
are nearly free, one is already solved by something else, and one is much
larger than it sounds.

## Where it already is

Twenty-odd products, and the shape of them matters more than the count:

| | |
|---|---|
| Shell | `LavaShell`, `LavaDock`, `LavaTaskbar` (clock, calendar, tray, volume, MPRIS chip), `LavaLauncher`, `LavaSwitcher`, `LavaContextMenu`, `LavaMenu` |
| Apps | `LavaTerm`, `LavaEditor`, `LavaView`, `LavaWeather`, `LavaSpotify`, `TraceLoom`, `LavaSettings` |
| Tools | `LavaDebug`, `LavaBench`, `LavaCtl`, `LavaChooser` |
| Framework | `LavaUI` (25k lines), the C++ `canvas` engine, the compositor, `nprpc` control plane |

Three things make a new app cheap now, and they are worth naming because every
estimate below leans on them. `LavaUI` has the widget set an app actually needs
— `ScrollView`, `LazyGrid`, `SplitView`, `TextField`, `ComboBox`, `Slider`,
`Toggle`, `ColorPicker`, `MarkdownView`, `Canvas`, menus, overlays, animation,
theming. The control plane means an app draws through the compositor and does
not link Vulkan. And the shell furniture — panel, dock, launcher, tray, MPRIS,
notifications — already exists, so a new app inherits a place to live rather
than having to build one.

## Three gaps that are not apps

These block or degrade several of the apps below at once. Doing them first is
worth more than any single app on the list.

### 1. ~~A file dropped on a Lava window goes nowhere~~ — fixed 2026-09-08

**Was:** `DropTarget.swift`, `DropRouter`, `DropBridge`, the `.fileDrop` event
and `LavaClientApp`'s provider were all built and all correct, and
`TakeDroppedPaths` on the compositor — the one call at the end of that chain —
was `return {}`. `docs/client-server-gaps.md` recorded the whole thing as
fixed, and it was, against the GLFW-hosted compositor that no longer exists;
the wlroots one never got the other half. So from the moment the desktop became
a real compositor, dropping a file on a Lava window did nothing.

**Fixed**, and it took two fixes rather than one. The compositor is now the drop
target — wlroots cannot be, since its drop path needs a `wl_surface` to have
taken the drag focus and a Lava client has none — so it pipes `text/uri-list`
off the drag source, reads it without blocking, and queues the paths for the
surface underneath. Beneath that was a second bug, in LavaUI: drops resolved
through `hitTestHover`, which returns the topmost node under the pointer rather
than the one holding the handler, so even a delivered drop went nowhere. See
`docs/client-server-gaps.md` §3.

Everything wanted this, which is why it was first: a photograph dropped on
LavaView, a file on the terminal, an image into Paint — and a file manager,
which is the app that cannot be written without it.

### 2. The desktop's file picker is a GTK subprocess

`FileDialog` shells out to `zenity` (`Sources/LavaUI/FileDialog.swift:5`), and
says so honestly. It works, and it is the single most visible seam in the whole
desktop: every Open… in every Lava app raises a GTK window that looks like
nothing else on screen, and on a machine without zenity it silently returns nil.

This is not a separate project from the file explorer — a chooser is a file
explorer with a different bottom bar. Build the browsing core once and let both
use it.

### 3. A client still cannot open a second window

Open since the client/server audit (`docs/client-server-gaps.md` §4).
`LavaClient` creates one arena and one surface. A file manager wants a second
folder window, a notes app wants a detached note, an editor wants a second file
side by side. Every app on the list below is shaped around this limit today.

**Medium**, and structural rather than fiddly: arenas, surfaces and the input
subscription are all one-per-process assumptions in `LavaClientApp`.

## The apps, assessed

### Video player — do not build one

The instinct that this fights the design is right, and the conclusion that it
needs codecs in the compositor is not.

A LavaUI client has no GPU and no codec by design; frames would have to cross
shared memory and be uploaded per frame, keyed by content hash — 8 MB hashed
and uploaded 30 times a second, through a texture cache built on the assumption
that a texture outlives its frame. That is the wrong shape, and no amount of
work makes it the right one.

But the compositor already imports a foreign client's live buffer as a canvas
texture: `importBufferTexture(wlr_buffer*, key, maxSide)`, used today to make
Alt+Tab posters out of running windows (`compositor/src/main.cpp:6013`). So
there are two honest answers, and neither involves a codec in the compositor:

- **mpv, as an ordinary Wayland client.** It works on this desktop right now,
  today, with hardware decode, subtitles, and every format. Cost: nothing.
- **A Lava shell around an embedded surface**, if you want the desktop's own
  chrome, playlist and keybindings: a LavaUI window whose content region is a
  foreign surface imported per frame, with mpv or libmpv behind it. Cost:
  **large** — the poster path is a snapshot on demand, and making it a live
  per-frame import with correct sizing, input routing and lifetime is new
  compositor work.

Recommendation: use mpv. Revisit only if the seam actually bothers you.

### Music player — build the browser, not the player

Same trick, and here it is stronger, because the control half already exists.
`CMpris`, `LavaMpris` and the taskbar's `PlayerApplet` already speak MPRIS;
`CPulse` already does volume. What is missing is not playback — it is a library:
scanning a music folder, reading ID3 tags, and a browse-and-queue UI.

Decoding MP3 yourself means an audio decoder plus a PipeWire output stream plus
a resampler plus gapless handling, and gets you a worse mpv. Driving mpv (or
playerctl) over MPRIS gets you a real player under your own UI, and the chip in
the panel already lights up for it.

**Medium.** Tag reading (TagLib, or a small ID3v2 reader — the format is
simpler than EXIF, which is already in the tree) and a library index are the
real work; the UI is `LazyGrid` plus `ScrollView`.

### File explorer — the big one, and the one worth doing

The largest item on the list, and the one with the most leverage: it gives the
desktop a native file chooser (gap 2), it forces file drops (gap 1), and it is
what makes a desktop feel like a desktop.

What exists: `SplitView` for the sidebar, `LazyGrid` and `ScrollView` for the
pane, `ImageStore` and the atlas for thumbnails (already tuned for exactly this
— small images, many of them), `ImageFormats` to know what has a thumbnail,
context menus, `FileDialog` to be replaced.

What does not: a directory model with sorting and filtering, a watcher
(`inotify`), rename/copy/move with progress and conflict handling, the
freedesktop **Trash** spec (nothing in the tree implements it), removable media
via **udisks**, and archive browsing. None of that is exotic; all of it is real.

**FTP specifically: do not build a VFS.** Put a `FileSource` protocol in front
of the local filesystem from the first commit — `list`, `stat`, `read`,
`write`, `delete` — and implement local first. Then remote is either `gvfs`
(the desktop already lives among GTK apps that use it, and it gives you SFTP,
SMB, MTP and FTP at once) or `libcurl` for the two or three protocols you
actually want. Retrofitting that seam later is the expensive version.

**Large.** Sequence it: browse and open → the chooser mode → operations and
Trash → watching → remote. The first of those is `LavaExplorer` —
`docs/lavaexplorer.md` — a one-pane window that lists a folder and opens
files, with no delete on purpose.

### Paint — the most self-contained thing on the list

Nothing about it needs the compositor to change. `Canvas.swift` gives an
immediate-mode drawing surface, `ColorPicker` exists, `canvas::encodeRgbaPng`
and `encodeRgbaJpeg` already write files, `SaveTarget` already handles "this
format cannot be written back" honestly.

New: a pixel buffer as the document, brush rasterisation (a circle stamped
along an interpolated stroke, which is most of it), flood fill, selection, and
undo as a stack of tiles. No new dependency, no new IDL, no new compositor
work.

**Medium**, and unusually predictable — it is all inside one process.

### Notes — the smallest real app

`LavaEditor` is 1.7k lines and already does tabs, find and syntax colouring;
`LavaText` is the text engine under it; `MarkdownView` renders. A notes app is
a store (a folder of markdown files), a list with search, and autosave.

**Small.** The interesting decision is whether it is a separate app or a mode
of `LavaEditor` — a "notes" root folder, a sidebar, and autosave would get most
of the value for a fraction of the work.

### Clock — mostly already there

The panel has a clock and a month calendar (`LavaTaskbar/CalendarApplet.swift`).
What a clock *app* adds is alarms, timers, a stopwatch and world clocks. Alarms
are the only part with real substance, and their cost is not the UI — it is
needing something alive when the app is not: a background service, a wake
schedule, and notifications (`Notifications.swift` exists, so the last step is
free).

**Small, and lowest value on the list.** Timers and a stopwatch as a panel
applet would probably serve better than an app.

## What is not on the list but should be

Things a desktop is judged on that nobody misses until they reach for them:

- ~~**A screenshot tool with annotation.**~~ Built — `LavaShot`, see
  `docs/lavashot.md`. It cost three control-plane calls (`CaptureScreen`,
  `SetClipboardImageFile`, `SetFullscreen`) and turned up the rule that a
  picture crosses as a path rather than as bytes.
- **Trash.** Not optional once a file manager exists; deleting for real is not
  something people forgive.
- **Archives.** A file manager that cannot look inside a `.zip` feels broken in
  a way that is hard to explain and easy to notice.
- **Removable media.** Plugging in a USB stick and having nothing happen is the
  single most "this is not finished" moment a desktop has.
- **A document viewer.** PDFs are the format people are handed. Poppler is a
  real dependency but a well-behaved one.
- **File search.** The launcher finds apps; nothing finds files.
- **Session and power.** Log out, suspend, restart — a menu somewhere, and
  whatever `LavaSettings` does not already cover.
- **Printing.** Worth naming to say it is out of scope: CUPS integration is a
  project on its own and print-to-PDF covers most of the need.

## A suggested order

Reasoned rather than ranked, and the reasoning is what to argue with:

1. ~~**File drops** (gap 1).~~ Done — and it cost two fixes, not one.
2. ~~**Screenshot + annotate.**~~ Done. The drawing model it established —
   strokes in a document, undo, a canvas for the picture and a layout overlay
   for the chrome — is what Paint should start from.
3. **Notes**, probably as a mode of `LavaEditor`. Smallest real app; proves the
   template.
4. **File explorer, core browsing** — then immediately **the chooser mode**,
   which retires the zenity seam and pays back across every app.
5. **Paint**, reusing whatever the screenshot annotator established.
6. **Music browser over MPRIS.** No decoder, no audio stack.
7. **File operations, Trash, watching, archives, media.** The unglamorous half
   of the file manager, which is what makes it a file manager.
8. **Second windows** (gap 3) whenever an app is actually shaped wrong without
   it — the file explorer will ask first.
9. **Video: nothing.** Use mpv. Revisit the embedded-surface path only if the
   seam bothers you in practice.
