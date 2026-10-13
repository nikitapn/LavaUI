# LavaPlayer — mpv, in a LavaUI window

LavaPlayer is the desktop's video player. mpv decodes and renders; LavaUI draws
everything around the picture — the title strip, the transport bar, the track
buttons and their menus. `LavaPlayer file.mkv` plays it with its folder as
Next/Previous, `LavaPlayer a.mp4 b.mp4` plays those one after another, and no
argument opens empty, ready for a drop.

| Concern | Where |
|---|---|
| Playlist and folder order, the clock, media and subtitle extensions, track labels | `Sources/LavaPlayerCore` (no engine, unit-tested) |
| Window, bars, keys, menus, the session | `Sources/LavaPlayerApp` |
| mpv on EGL, rendering into dma-bufs, the render thread | `Sources/CLavaVideo` |
| Importing those buffers and sampling them | IDL `AttachVideoBuffer` / `ShowVideoBuffer`, `CanvasRenderer::attachVideoBuffer`, `TextureManager::refreshFromImported` |

## How a frame reaches the screen

`docs/desktop-apps.md` once said not to build this, because a LavaUI client has
no GPU and a frame pushed through shared memory is the wrong shape. Both halves
are still true, and the player is built around them rather than against them.

libmpv has no Vulkan render API — only OpenGL and software — so `CLavaVideo`
opens a windowless EGL context on **the compositor's** render node
(`GetVideoTarget` names it, with the modifiers the compositor can import) and
runs mpv's GL renderer there, into three GBM buffers. Each is handed to the
compositor once as a dma-buf (`AttachVideoBuffer`, the first IDL call to carry
an `fd`); per frame the client `glFinish`es and names one (`ShowVideoBuffer`),
and the compositor copies it into a texture it keeps per buffer. The client's
draw list then draws that texture like any other image. No pixel touches the
CPU, and measured headless at 1100×600 a frame costs 0.77 ms round trip,
the copy included.

Three things are load-bearing, and AGENTS.md has the long form:

- **No acquire fence.** NVIDIA does not honour implicit ones, so the client's
  own `glFinish` is the fence — it costs the render thread and nobody else.
- **The reply is the release.** When `ShowVideoBuffer` returns the copy is
  done and mpv may render into that buffer again.
- **Buffers outlive a resize until the window has moved on.** A new size
  means a new set of buffers, and detaching the old set deletes its textures —
  while the window's last draw list still names them. Freed first, the video
  area went black for a frame or two on every resize (9 of 400 captures across
  six fullscreen toggles). Now the app reports the buffer each presented frame
  came from (`lava_video_shown`), and the old set goes only once that names
  the new one. A size must also hold for 100 ms before buffers are made for
  it, so dragging a window edge does not allocate three buffers per motion
  event; mpv draws into the old set meanwhile and the app fits it to the box.

Where the path will not come up — windowed under GLFW, an EGL extension
missing, an import refused — the bridge falls back to mpv's software renderer
and `uploadPixels`. Same player, several times the CPU. The startup line on
stderr says which: `dma-buf frames on /dev/dri/renderD128` or `software frames`.

The render GPU is never a choice: it is whatever the compositor runs on,
because a tiled buffer from another GPU cannot be imported at all. Decoding
follows it — mpv is given the render node, so `hwdec=auto-safe` picks VA-API
on that device. A codec that GPU cannot decode is decoded on the CPU and still
displayed without a copy; `LAVA_PLAYER_MPV="hwdec=nvdec-copy"` is the untested
way to try the other GPU's decoder instead.

## Seeking

Dragging the seek bar sends `absolute+keyframes` seeks — mpv shows the nearest
keyframe at once — and the release sends one `absolute+exact`, so a click still
lands on the frame. Exact seeks on every move were the original version, and on
a heavy file each was cancelled by the next before it decoded anything: the bar
moved and the picture did not. `Player.seek(to:exact:)`,
`PlayerSession.seekBarEditing`.

## Fullscreen

Windowed, the transport bar is a row under the video. In fullscreen the same
bar floats over the video's bottom edge as an overlay that takes no layout
space — so showing and hiding it never resizes the video, which would make mpv
render at a new size every time the pointer moved. It is at most 1000 pt wide,
centred, so the seek track is long without being edge to edge.

The bar and the pointer hide together after 2.5 s without movement, never
while paused, never while the pointer rests on the bar (`.onHover` on the bar
as a whole, children included), and never while a track menu is open. While
the bar is up, subtitles move above it (`sub-margin-y`), as mpv's own
controller does.

## Subtitles and audio tracks

mpv draws subtitles into the frame itself, at the box's resolution; the player
only chooses. It observes `track-list` and turns it into `Track` values
(`LavaPlayerCore/Tracks.swift`), which give each row its label —
`English — SDH`, `Japanese — Commentary`, `German (file)`.

- **The Subtitles menu**: off, every track, show/hide, timing ±0.1 s, and
  Load Subtitle File…. **The Audio menu**: every audio track.
- **CC**, on the bar when the file has subtitle tracks: a left click steps to
  the next track through off; a right click lists them all. Lit while a track
  is showing.
- **The audio button**, beside it when there is more than one audio track:
  reads the language playing (`ENG`, `#2` when none is named). A left click
  steps to the next track and wraps — never onto "no audio", which mpv's own
  `cycle audio` does on the way round. A right click lists them.
- **A dropped subtitle file** is loaded into the video playing, not opened in
  its place. `sub-auto=fuzzy` finds `Movie.2019.de.srt` beside
  `Movie.2019.mkv` without being asked.

Track commands go through `osd-msg`, so mpv confirms each change on the picture
in the frame it takes effect. Two things worth knowing before changing the
buttons: they are stacks with `onPointer`, because a `Text`'s `onClick` answers
every mouse button alike and a right click would step *and* open the list; and
a click on the video closes an open menu and does nothing else, because the
overlay lets an outside click reach a real target and the video is one that
covers the window.

## Keys

mpv's, where mpv has one.

| Key | Does |
|---|---|
| Space, P | Play / pause (at the end: from the start) |
| ← / → | Back / forward 5 s; with Shift, 60 s |
| ↑ / ↓, 0 / 9 | Volume ±5 |
| M | Mute |
| , / . | One frame back / forward |
| J / Shift+J | Next / previous subtitle track |
| V | Show / hide subtitles |
| Z / X | Subtitles 0.1 s earlier / later |
| # (Shift+3) | Next audio track |
| F, Enter | Fullscreen |
| Esc | Leave fullscreen |
| N, Page Down / Ctrl+P, Page Up | Next / previous file |
| Ctrl+O | Open |

A click on the video pauses, a double click goes fullscreen, and the wheel over
it is volume.

## Testing it without a screen

The headless recipe in AGENTS.md works as it is. `LAVA_PLAYER_MPV="ao=null"`
keeps the run silent; any other mpv option goes in the same variable. The
shell exports `LAVA_CLIENT=1`, so a windowed run needs `env -u LAVA_CLIENT`.
`LAVA_TEST_DROP=a.srt` on the compositor and `kill -USR1` deliver a drop.
Two things the agent cannot see: the global menu (no panel with
`LAVA_NO_SHELL=1`) and the floating bar through `find`, which walks the main
tree — click by coordinate.

A clip with tracks to choose from is one ffmpeg line:

```bash
ffmpeg -i video.mkv -f lavfi -i sine=440:duration=20 -f lavfi -i sine=880:duration=20 \
  -i en.srt -i fr.srt -map 0:v -map 1 -map 2 -map 3 -map 4 -c:v copy -c:a aac -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=fra out.mkv
```

## Known limitations

- **No MPRIS.** The panel's player applet and media keys do not see it.
- **`~/.config/mpv` is not read.** libmpv loads no config unless asked, and
  a user's config can name a `vo` or `hwdec` that breaks the bridge. Options
  go through `LAVA_PLAYER_MPV` until there is a settings page.
- **Styled ASS subtitles may sit under the floating bar.** The lift is a
  margin, and an ASS style that places its own lines ignores it.
- **No speed control, chapters, A–B loop, screenshots, or resume position.**
  All are one mpv property or command away; none has a control yet.
- **A real window-edge drag is untested headlessly.** The 100 ms settle is
  measured on fullscreen toggles; headless wlroots has no pointer to drag an
  edge with.
