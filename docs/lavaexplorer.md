# LavaExplorer — one folder, as a list

Thunar and Explorer, not Midnight Commander: a places list on the left, a
details list on the right, an address bar along the top. Double-click a
folder to go in; double-click a file and the desktop opens it.

This started as the **browse and open** slice from `docs/desktop-apps.md`.
It now copies by drop, makes and renames folders and files, and throws
away into the desktop's Trash; cut and paste are still to come.

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
- Back / Forward / Up, Alt+arrows, Backspace to go up. Back and Forward
  land on a folder as it was left — the same rows selected, scrolled to
  exactly where it was — so Back from a folder you opened puts you on it.
  Up selects the folder you came out of, with a few rows above it. Each tab
  keeps its own place in its list, across tab switches and moves between
  panes.
- New Folder (the toolbar button, File → New Folder, Ctrl+Shift+N) opens a
  row at the top of the list with "New Folder" selected — or "New Folder
  (2)" when that is taken — to type over. Enter makes it and selects it
  where it sorts; Escape, or going to another folder, forgets it. Nothing is
  made until Enter, and a name already there is refused rather than merged
  into. Not in the Trash.
- F2 (or Rename on the right-click menu or the Edit menu) turns the row's
  name into a field, with the name up to its extension selected — "report"
  of "report.pdf" — for a folder all of it. Enter renames it in place and
  keeps it selected where it now sorts; Escape, or going elsewhere, leaves
  it as it was. A name something else already has is refused, never
  replaced. Ctrl+Z renames it back, unless something has since taken the
  old name. Not in the Trash: restore it first.
- **The desktop's file picker.** `FileDialog` — Open… and Save As… in every
  Lava app — runs `LavaExplorer --choose=open|open-multiple|save` instead of
  zenity: the same window with a bar along the bottom. Open shows what is
  picked (several rows with `open-multiple`); a folder is gone into, a file
  double-clicked is the answer. Save has a name field with the stem
  selected; a file clicked puts its name there, and saving over one asks
  first. The app's filters are a dropdown (with "All files" after them),
  and folders always show. Cancel, Escape, closing the window or closing
  the last tab all mean "nothing chosen". The answer goes to the file named
  by `--output`, one path per line — never stdout, which the app fills with
  whatever it likes. It opens where the caller's last dialog chose from,
  else home. Everything else — tabs, panes, New Folder, rename, the Trash —
  works inside it.
- Rows do not light up under the pointer. A list scrolled under a still
  pointer slides row after row beneath it, and a tint that follows reads as
  flicker; selection is the only fill a row has.
- Ctrl+Z undoes, Ctrl+Shift+Z (or Ctrl+Y) redoes, and both are on the Edit
  menu. Every undo goes through the Trash or is a rename back: a move to the
  Trash is undone by restoring, a restore by moving back, a copy or a new
  folder by moving it to the Trash — never by deleting it — and a rename by
  renaming back, so an undo made by mistake is itself recoverable. Deleting for good cannot be undone, and neither can a
  file a copy replaced: the old contents are gone. Fifty steps, per window.
- Hidden names stay out until View → Show Hidden Files (or Ctrl+H).
- Enter opens the selected row. A drop of a path navigates there.
- Several rows at once: Ctrl+click adds or removes one, Shift+click selects
  the range from the last row clicked, Ctrl+Shift+click adds that range,
  Shift+Up/Down grows it from the keyboard, Ctrl+A takes the whole folder
  and Escape lets go. Delete, Move to Trash, Delete Permanently, Restore,
  Copy Path (one per line) and a drag act on all of them; the drag's chip
  says how many more it carries. Pressing one of several selected rows keeps
  the rest until the button comes up, so the group can be dragged, and a
  right-click on a row outside the selection is about that row alone.
- Drop files — from another app, or rows dragged out of this window,
  another pane included — to put them in a folder: onto a folder row, into that folder;
  onto a pane's list, into the folder the pane shows; onto a tab or a place
  in the sidebar, into its folder. What the drag is aimed at lights up. A
  drag that rests on a tab for a moment opens it, so a folder inside is
  there to drop on. Letting a row go in the folder it came from does
  nothing. Names already there get one question for the whole
  drop: Replace (a folder is merged into, not swapped out), Keep Both
  ("report (2).pdf"), Skip, or Cancel. A file is replaced only once its copy
  is complete. The copy runs off the frame loop, and every tab showing that
  folder reloads when it finishes. No progress bar yet.
- Moved or copied is Explorer's rule: a drop on the same filesystem moves
  (a rename — instant, whatever the size), one onto another drive copies,
  and a drop of both kinds does each. Replace on a move renames a file over
  the old one in one step and merges a folder in, removing the emptied
  source. A rename that fails across a mount the check did not see falls
  back to a copy and leaves the original. Ctrl+Z moves things back, and a
  mixed drop is one undo.
- A tab open inside a folder that is renamed or moved — by this window, or
  by its undo — follows it: its path, its Back and Forward, and its
  selection.
- Copy Path puts a filesystem path on the clipboard. It does not copy the file.
- Right-click: Open, Open With, Set Default App, Move to Trash, Delete
  Permanently, Rename, and stubs for copy, cut and paste.
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
  the plus on the strip, middle-click a folder, or Open in New Tab. Closing
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

Copy, cut and paste are on the menu as stubs: they say so in the status
bar and do not touch the disk.

MIME type and the default handler are read in-process (extension table and
`mimeapps.list`). Asking `gio` / `xdg-mime` from the menu body spawned a
process per visible row on every rebuild — overlays stay mounted while
hidden — and that is what made the list stutter. The menu sits on the
row, not the pane: a pane-sized overlay swallowed clicks on every other
file.

## What it does not

- **Cut and paste, copy from the menu, and Ctrl/Shift on a drop.** Cut,
  copy and paste are on the context menu as labelled stubs. A drop cannot
  yet be forced to copy (Ctrl) or to move (Shift): nothing in LavaUI tracks
  which modifiers are held while a drag is over the window. Writes are a
  drop (a move or a copy), New Folder, Rename, the Trash
  (a rename), and a removal that has been asked about. `FileSource` still has
  no `delete`: throwing away goes through `TrashCan`, and removing for good
  through `FileEraser`, which only the confirmed paths reach.
- **Rubber-band selection.** Rows are picked with the keyboard and
  Ctrl/Shift+click; dragging on empty space does not draw a box yet.
- **Thumbnails.** The list is glyphs. Icon view with `ImageStore` is the
  next visual step, not this one.
- **inotify.** Reload is a key (Ctrl+R) and a menu item.
- **A second window.** One surface per process; navigate in place.
- **Archives, removable media, search, remote.** Later.

## The `FileSource` seam

`list` and `stat` (as `entries(in:)` and `entry(at:)`), implemented first for
the local disk. A later SFTP or gvfs source is another type.
`TrashListingSource` wraps one and answers for `trash:///` as well; entries
listed there keep their real path in the trash's `files/`, which is what
opens, drags and restores. Write and delete stay off the protocol.
