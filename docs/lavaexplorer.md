# LavaExplorer — one folder, as a list

Thunar and Explorer, not Midnight Commander: a places list on the left, a
details list on the right, an address bar along the top. Double-click a
folder to go in; double-click a file and the desktop opens it.

This is the **browse and open** slice from `docs/desktop-apps.md`. There is
no delete, no trash, no rename, no copy of the files themselves. Those wait
until the operations are safe enough to put in front of a whole disk.

```bash
swift run LavaExplorer
LAVA_CLIENT=1 swift run LavaExplorer -- ~/Pictures
```

| Concern | Where |
|---|---|
| Listing, sort, history, places, the `FileSource` seam | `Sources/LavaExplorerCore` (no engine, unit-tested) |
| Window, keys, `xdg-open` | `Sources/LavaExplorerApp` |

## What it does

- Opens on `$HOME`, or on the folder (or the parent of the file) named on the
  command line.
- Places: Home, the XDG user directories that exist, Computer (`/`).
- Details list: name, size, date. Folders first. Click a column to sort.
- Back / Forward / Up, Alt+arrows, Backspace to go up.
- Hidden names stay out until View → Show Hidden Files (or Ctrl+H).
- Enter opens the selected row. A drop of a path navigates there.
- Copy Path puts a filesystem path on the clipboard. It does not copy the file.
- Right-click: Open, Open With, Set Default App, and stubs for copy/delete.
- Drag a row out and drop it on another window — LavaView, a terminal, VS
  Code, a browser's upload box. A chip with the row's glyph and name follows
  the pointer. Offered as a copy only; let go on the window it came from and
  nothing happens.
- Tabs: each has its own folder and Back stack. Ctrl+T / Ctrl+W, Ctrl+Tab,
  the plus on the strip, Ctrl+click a folder, or Open in New Tab. Closing
  the last tab closes the window. Several paths on the command line open
  one tab each.

Opening a file on double-click is `xdg-open`, which honours the default
handler. Right-click offers **Open With** (launch this once) and **Set
Default App** (writes `xdg-mime default`, so the next double-click uses
that app). Both lists come from installed `.desktop` files that claimed
the file's MIME type — `inode/directory` for a folder, so this is also
how LavaExplorer becomes the default file manager without a trip to the
CLI. Picking LavaExplorer writes a user `.desktop` under
`~/.local/share/applications` if packaging has not installed one yet, then
runs `xdg-mime default`.

Copy, cut, paste, rename and delete are on the menu as stubs: they say so
in the status bar and do not touch the disk.

MIME type and the default handler are read in-process (extension table and
`mimeapps.list`). Asking `gio` / `xdg-mime` from the menu body spawned a
process per visible row on every rebuild — overlays stay mounted while
hidden — and that is what made the list stutter. The menu sits on the
row, not the pane: a pane-sized overlay swallowed clicks on every other
file.

## What it does not

- **Delete, trash, rename, new folder, copy, move.** On the context menu
  as labelled stubs. A file manager that can throw things away without a
  bin is how people lose work; `FileSource` has no `delete` so the method
  cannot be called by accident.
- **Thumbnails.** The list is glyphs. Icon view with `ImageStore` is the
  next visual step, not this one.
- **inotify.** Reload is a key (Ctrl+R) and a menu item.
- **A second window.** One surface per process; navigate in place.
- **Dragging within the window.** Nothing takes a drop on a folder row yet, so
  a row dragged onto another folder is not moved or copied there — a drop
  anywhere still navigates. One row at a time, because selection is one row.
- **The chooser mode.** `FileDialog` still shells out to zenity. The browsing
  core is what that mode should sit on, once it exists.
- **Archives, removable media, search, remote.** Later.

## The `FileSource` seam

`list` and `stat` (as `entries(in:)` and `entry(at:)`), implemented first for
the local disk. A later SFTP or gvfs source is another type. Write and
delete stay off the protocol until Trash is real.
