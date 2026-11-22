# LavaEditor — what comes next

Written 2026-11-22, at the end of a session that landed libgit2, the
two-editor diff, per-document undo, the terminal panel and editor extensions.
Ordered by what to do first.

## 1. Worktree and branch switcher

Small; libgit2 (`Sources/LavaGitCore`) is already the git layer.

- The branch chip (Source Control header, status bar) becomes a picker: local
  branches, then this repository's worktrees (`git_worktree_list`,
  `git_branch_iterator`), each with its path and ahead/behind or dirty state.
- **Worktree** → switch the open folder to it. No checkout, so instant and safe
  with unsaved buffers; each worktree keeps its own tabs (the session snapshot
  is per folder already — check `SessionPersistence`).
- **Branch** → checkout in place, refused with the list of files when it would
  overwrite local changes (what `git switch` does; libgit2's
  `GIT_CHECKOUT_SAFE` reports conflicts). Afterwards reload documents whose
  files changed and refresh the gutter's HEAD copies.
- Later: Codex's worktrees (`../HelloWorld-*`) with status, so checking an
  agent's branch is two clicks.

## 2. Inline chat on a line, with a chosen Claude Code or Codex session

Both CLIs on this machine support driving a specific session from a program
(checked against `--help`, 2026-11-22):

- **Claude Code**: `claude -p --resume <id> --input-format stream-json
  --output-format stream-json` streams the reply, tool calls and edits;
  `--fork-session` resumes into a *new* id instead of appending to a session
  that may be open in a terminal at the same moment — two writers on one
  session is the real hazard, so fork by default and offer "continue in place"
  explicitly. Sessions are files under `~/.claude/projects/<encoded cwd>/*.jsonl`,
  so the picker can list this project's sessions with first prompt and date.
- **Codex**: `codex exec resume <id> --json` (JSONL events), `codex exec fork`,
  `codex queue` (message an existing session); `codex app-server` is the richer
  protocol its VS Code extension uses, but marked experimental.

Editor side:

1. **Ctrl+I** on a line or selection opens a box *between* lines — the same
   mechanism as diff filler and test hints (`RowGaps` rows reserved above or
   below the line), with a real text field placed over the gap (the editor
   would report the gap's frame, like `EditorPopupAnchors` does for popups).
2. A picker at the box's top chooses the session: this project's Claude / Codex
   sessions, or a new one.
3. The prompt goes with a reference (`Sources/X.swift:120-134`) and the
   selected text; the reply streams into the box.
4. Edits are not applied directly: they open as the side-by-side diff
   (`DiffPane`), accept/reject, one undo step on accept.

Start with Claude (stream-json + fork covers it), add Codex after.

Separately worth a look later: `claude --ide` connects to an IDE over the
protocol the VS Code / JetBrains plugins implement, which is what lets a
`claude` in a terminal see the editor's selection and open diffs in the editor.
LavaEditor serving it would make `claude` in the terminal panel selection-aware
with no chat UI at all. Unknown how documented/stable that protocol is.

## 3. Embedding the other apps (from the earlier list)

- **Image viewer in a tab** — `LavaViewCore.Viewport` is already pure; a binary
  image file opens zoomable instead of as an invalid-UTF-8 buffer. First case
  of "a tab that is not text", which video needs too.
- **Video in a tab** — LavaPlayer's dma-buf path works; owning an mpv instance
  per tab and tearing it down cleanly is the risky part.

## Smaller open items

- Diff: hide unchanged regions (the same idea as `RowGaps`, removing rows
  instead of adding them); a per-hunk "revert this change" arrow.
- LSP: restart servers on settings change, stop them on folder change, snippet
  tab-stop navigation; the trust prompt for unknown workspace servers that can
  whitelist into user settings.
- Undo history is per document now but not saved across restarts, and a reload
  from disk clears it.
- Extensions: a ring size chosen by the client in NPRPC, so a small extension
  does not get the 12 MiB-each-way ring (see AGENTS.md, extensions row);
  a reused worker that crashes between calls costs one failed discovery before
  it restarts.
- Terminal: full-screen programs (vim, htop) in the panel and dragging the
  split are untested; real-keyboard punctuation (compositor `glfw_key`) only
  checked by the user, not headless.
