# LavaExplorer — one folder, as a list

Thunar and Explorer, not Midnight Commander: a places list on the left, a
details list on the right, an address bar along the top. Double-click a
folder to go in; double-click a file and the desktop opens it.

This started as the **browse and open** slice from `docs/desktop-apps.md`.
It now copies by drop and throws away into the desktop's Trash; rename,
cut and paste are still to come.

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
  Drag the line between two headings to resize: Size and Modified keep
  their widths, Name takes what is left, and every pane shares one set.
- Back / Forward / Up, Alt+arrows, Backspace to go up.
- Hidden names stay out until View → Show Hidden Files (or Ctrl+H).
- Enter opens the selected row. A drop of a path navigates there.
- Drop files — from another app, or rows dragged out of this window,
  another pane included — to copy them: onto a folder row, into that folder;
  onto a pane's list, into the folder the pane shows; onto a tab or a place
  in the sidebar, into its folder. What the drag is aimed at lights up. A
  drag that rests on a tab for a moment opens it, so a folder inside is
  there to drop on. Letting a row go in the folder it came from does
  nothing. Names already there get one question for the whole
  drop: Replace (a folder is merged into, not swapped out), Keep Both
  ("report (2).pdf"), Skip, or Cancel. A file is replaced only once its copy
  is complete. The copy runs off the frame loop, and every tab showing that
  folder reloads when it finishes. No progress bar yet.
- Copy Path puts a filesystem path on the clipboard. It does not copy the file.
- Right-click: Open, Open With, Set Default App, Move to Trash, Delete
  Permanently, and stubs for copy, cut, paste and rename.
- Delete (or Move to Trash, or a drop on the Trash place) throws the
  selection away into the freedesktop Trash — the one Nautilus, Dolphin,
  Thunar and `gio trash` share, so each restores what the others threw
  away. It is a rename, never a copy: a file on another drive goes to that
  drive's `.Trash-$uid` (or an administrator's sticky `.Trash/$uid`), with
  its path recorded relative to the drive. A file that cannot be trashed —
  a drive with no room for a trash, say — is left alone and the status bar
  says Shift+Delete removes it for good.
- The Trash is a place (`trash:///`): everything in every trash directory
  on the machine, under the names it had, with the date it was deleted. The
  status bar says where the selected item came from. Right-click Restore
  puts it back, recreating its folder if that went too, and refuses rather
  than overwrite something new by that name. Empty Trash empties all of it.
- Shift+Delete, Delete inside the Trash, Delete Permanently and Empty Trash
  remove for good, and each asks first in a bar along the bottom (Escape is
  Cancel). The removal runs off the frame loop.
- Drag a row out and drop it on another window — LavaView, a terminal, VS
  Code, a browser's upload box. A chip with the row's glyph and name follows
  the pointer. Offered as a copy only; let go on the window it came from and
  nothing happens.
- Tabs: each has its own folder and Back stack. Ctrl+T / Ctrl+W, Ctrl+Tab,
  the plus on the strip, Ctrl+click a folder, or Open in New Tab. Closing
  the last tab closes the window. Several paths on the command line open
  one tab each. Tabs keep their width; a strip that runs out of room scrolls
  (the wheel over it), and the selected tab is scrolled into view when it
  changes. Drag a tab along a strip to reorder it — a bar marks the gap — or
  onto another pane's strip to put it at that place there.
- Panes: drag a tab and the pane under the pointer shows where it would
  land. Near an edge — the outer quarter — is a new pane on that side,
  halving that pane; the middle or a pane's tab strip moves the tab into that
  pane. Splits nest in either direction and their dividers drag. Each pane
  has its own tabs, address bar and list; a press anywhere in a pane makes it
  the one keys, menus, the sidebar and the status bar act on. A pane that
  loses its last tab closes. The window buttons live on the sidebar's title
  row, the one strip that stays in the corner however the panes are split.

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

- **Rename, new folder, move, cut and paste — and copy from the menu.** On
  the context menu as labelled stubs. Writes are a drop (a copy), the Trash
  (a rename), and a removal that has been asked about. `FileSource` still has
  no `delete`: throwing away goes through `TrashCan`, and removing for good
  through `FileEraser`, which only the confirmed paths reach.
- **Undo.** Restore from the Trash is the way back; there is no Ctrl+Z.
- **More than one row at a time.** Selection is one row, so Delete is one
  item; `TrashCan` and the erase path already take lists.
- **Thumbnails.** The list is glyphs. Icon view with `ImageStore` is the
  next visual step, not this one.
- **inotify.** Reload is a key (Ctrl+R) and a menu item.
- **A second window.** One surface per process; navigate in place.
- **The chooser mode.** `FileDialog` still shells out to zenity. The browsing
  core is what that mode should sit on, once it exists.
- **Archives, removable media, search, remote.** Later.

## The `FileSource` seam

`list` and `stat` (as `entries(in:)` and `entry(at:)`), implemented first for
the local disk. A later SFTP or gvfs source is another type.
`TrashListingSource` wraps one and answers for `trash:///` as well; entries
listed there keep their real path in the trash's `files/`, which is what
opens, drags and restores. Write and delete stay off the protocol.
