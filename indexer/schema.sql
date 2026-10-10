-- LavaIndex: the file index, one SQLite database per user.
--
-- Lives at $XDG_DATA_HOME/lava/index.db (~/.local/share/lava/index.db). The
-- daemon is its only writer. Nothing else should open it read-write; a client
-- that opens it at all is reading a private format — `idl/index.npidl` is the
-- contract, this file is not.
--
-- It indexes *names and metadata*, not contents: what the search window shows
-- is a name, a folder, a size and a date. Text inside PDFs is a second table
-- for later, filled off the hot path, and nothing here has to change for it.
--
-- `PRAGMA user_version` is the schema version. The daemon refuses a database
-- newer than it understands and migrates an older one — or, since every row
-- here can be rebuilt from the disk, simply deletes it and crawls again.

PRAGMA journal_mode = WAL;      -- searches never wait for a crawl's commit
PRAGMA synchronous = NORMAL;    -- a lost last transaction is a rescan, not a loss
PRAGMA foreign_keys = ON;
PRAGMA user_version = 1;

-- A directory tree the user asked to have indexed: ~/Documents,
-- /mnt/windows/Learning. Copied in from the config on start, so an id is
-- stable for as long as the path stays configured.
--
-- A root is not assumed to be watchable, or to stay as it was found. The
-- Windows partition is the case in point: it is mounted read-only today
-- because the volume is dirty, and becomes writable again the day it is
-- fsck'd from Windows. Two facts follow and neither is special to NTFS:
--
--   * Changes made while it was not mounted here — by Windows — produce no
--     event anywhere. So every root is *reconciled* when it appears: on
--     daemon start, and whenever /proc/self/mountinfo says the mount changed
--     (mounted, remounted rw). A reconcile walks the tree and compares each
--     directory's listing with its rows, writing only the difference — a
--     file deleted from Windows leaves the index then. A root that is not
--     mounted keeps its rows and is reported as offline rather than emptied.
--   * Whether events are watched is decided from the mount *now*, not from
--     its type. A FUSE mount (ntfs-3g is `fuseblk`) still delivers inotify
--     for changes made through it, so a writable one is watched like ext4.
CREATE TABLE root (
  id                 INTEGER PRIMARY KEY,
  path               TEXT    NOT NULL UNIQUE,   -- absolute, no trailing slash
  -- Which filesystem the root was found on: the mount's source and the
  -- directory of it that is mounted ("/dev/nvme0n1p2 /"). Not a device
  -- number — a FUSE mount gets a fresh anonymous one on every mount — and not
  -- the fs type, which changes if ntfs-3g is swapped for ntfs3.
  --
  -- A root whose filesystem no longer matches is reported offline and left
  -- alone, *not* re-crawled. The common way to get a mismatch is an
  -- unmounted mount point: the path still exists, it is just an empty
  -- directory on the parent filesystem, and reconciling against that would
  -- delete every row. `Index.Rescan` is how a genuinely new disk is adopted.
  filesystem         TEXT    NOT NULL DEFAULT '',
  last_reconcile_ns  INTEGER NOT NULL DEFAULT 0
);

-- Every file and directory under a root, as a tree.
--
-- A parent pointer and a name, not a full path. Renaming ~/Videos/Talks is
-- one UPDATE rather than one per file under it, and a path is a few hundred
-- bytes against eight for an id — at a few million rows the difference is the
-- size of the database. A path is rebuilt by walking `parent` up, which for
-- a page of hits is a few hundred primary-key lookups — microseconds each;
-- `entry_path` below does the same in SQL, for poking at the file by hand.
CREATE TABLE entry (
  id          INTEGER PRIMARY KEY,
  -- NULL only for a root's own directory.
  parent      INTEGER REFERENCES entry(id) ON DELETE CASCADE,
  root        INTEGER NOT NULL REFERENCES root(id) ON DELETE CASCADE,
  name        TEXT    NOT NULL,
  kind        INTEGER NOT NULL,   -- 0 file, 1 directory, 2 symlink (not followed)
  size        INTEGER NOT NULL DEFAULT 0,   -- bytes; 0 for a directory
  mtime_ns    INTEGER NOT NULL DEFAULT 0,
  -- Lowercased extension without the dot, '' for none. The badge in the
  -- search window and the category filter both read it, and both would
  -- otherwise re-derive it from `name` on every row of every query.
  ext         TEXT    NOT NULL DEFAULT '',
  -- Recorded, not yet used: the way to tell a rename from a delete and a
  -- create during a reconcile, where there is no inotify cookie to pair the
  -- two halves. Unreliable on FUSE — ntfs-3g synthesises inode numbers — so
  -- it can only ever be a hint, never an identity.
  ino         INTEGER NOT NULL DEFAULT 0
);

-- One name per directory. Also the index every inotify event and every
-- reconcile resolves through: both think in (directory, name).
CREATE UNIQUE INDEX entry_by_parent_name ON entry(parent, name);
-- Entry counts per root, for `Index.Status`.
CREATE INDEX entry_by_root ON entry(root);
-- The category filter (videos, documents …) without a scan.
CREATE INDEX entry_by_ext ON entry(ext);
-- Queries of one or two characters: a trigram index has nothing to say about
-- them, so they fall back to a prefix match on the folded name.
CREATE INDEX entry_by_name_nocase ON entry(name COLLATE NOCASE);

-- Substring search over names.
--
-- `trigram` makes any substring of three characters or more an index lookup,
-- which is what a search box wants: "report" finds "Quarterly Report Q3.pdf"
-- without the user typing from the start of a word. External content, so the
-- names are stored once (in `entry`) and this holds only the index.
-- Case- and accent-insensitive: "resume" finds "Résumé.pdf".
--
-- Ranking is not done here. FTS hands back candidates; the daemon scores them
-- (whole-name prefix, then word start, then substring, then how recently it
-- was opened and which root it is in) and returns the best `limit`.
CREATE VIRTUAL TABLE entry_fts USING fts5(
  name,
  content = 'entry',
  content_rowid = 'id',
  tokenize = 'trigram case_sensitive 0 remove_diacritics 1'
);

CREATE TRIGGER entry_ai AFTER INSERT ON entry BEGIN
  INSERT INTO entry_fts(rowid, name) VALUES (new.id, new.name);
END;
CREATE TRIGGER entry_ad AFTER DELETE ON entry BEGIN
  INSERT INTO entry_fts(entry_fts, rowid, name) VALUES ('delete', old.id, old.name);
END;
-- Only a rename touches the index. A size or mtime change is the common
-- update by far, and would otherwise rewrite the trigrams for nothing.
CREATE TRIGGER entry_au AFTER UPDATE OF name ON entry BEGIN
  INSERT INTO entry_fts(entry_fts, rowid, name) VALUES ('delete', old.id, old.name);
  INSERT INTO entry_fts(rowid, name) VALUES (new.id, new.name);
END;

-- What the user opened, and when: the "Recent" list.
--
-- Keyed by path rather than by entry, on purpose. Recent things are often
-- outside every root — a download opened straight from a browser, a file on a
-- USB stick — and must survive a reconcile that drops and recreates their
-- entry. A recent path that no longer exists is checked with one stat when
-- the list is asked for, and pruned then.
--
-- Two sources: ~/.local/share/recently-used.xbel, which GTK and Qt apps
-- write and the daemon re-reads when it changes, and `Index.NoteOpened`,
-- which is how Lava's own apps say so without going through a GTK file.
CREATE TABLE recent (
  path          TEXT    PRIMARY KEY,
  last_open_ns  INTEGER NOT NULL,
  open_count    INTEGER NOT NULL DEFAULT 1,
  -- Who said so last: 'xbel', or the app id that called NoteOpened.
  source        TEXT    NOT NULL
) WITHOUT ROWID;

CREATE INDEX recent_by_time ON recent(last_open_ns DESC);

-- An entry's full path, for debugging only. The daemon never queries this:
-- it walks up one hit at a time with a prepared statement.
CREATE VIEW entry_path AS
WITH RECURSIVE up(id, leaf, parent, path) AS (
  SELECT e.id, e.id, e.parent,
         CASE WHEN e.parent IS NULL THEN r.path ELSE e.name END
  FROM entry e JOIN root r ON r.id = e.root
  UNION ALL
  SELECT p.id, up.leaf, p.parent,
         CASE WHEN p.parent IS NULL THEN r.path ELSE p.name END || '/' || up.path
  FROM up
  JOIN entry p ON p.id = up.parent
  JOIN root  r ON r.id = p.root
)
SELECT leaf AS id, path FROM up WHERE parent IS NULL;
