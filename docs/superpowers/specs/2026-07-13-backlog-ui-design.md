# Backlog in the UI, drop-to-attach media, centered footer — design

Date: 2026-07-13 · Approved in-session by Michael

## Goals

1. Open `docs/BACKLOG.md` from the command palette (search bar).
2. Drop images/videos onto the markdown preview in edit mode; the file is
   copied into a sibling media folder and a link is inserted at the caret.
3. Center the sidebar-footer controls on one aligned row; the notification
   popover must not clip and the bell keeps its Settings hide toggle.

## 1. Backlog palette command

- One `Command` in the ⌘K palette's Navigate group: label "Backlog",
  hint `docs/BACKLOG.md`, icon `ListChecks`.
- `run` calls the existing `requestFile(`${workspacePath}/docs/BACKLOG.md`)`
  flow, which opens the file in `FilesView`/`DocumentPreview`.
- The entry appears only when `docs/BACKLOG.md` exists in the active
  workspace (checked with `bridge.fs.read` each time the palette opens in
  commands mode), since the backlog is a per-project convention.

## 2. Drop-to-attach media in the markdown preview

- New IPC `fs:importAsset { source, targetDir, name }` in
  `electron/ipc/fsHandler.cjs`: `mkdir -p targetDir`, collision-safe name
  (`name-2.ext`, `COPYFILE_EXCL`), `copyFile(source → target)`. Exposed as
  `bridge.fs.importAsset` (preload + bridge types). Copy-by-path (the dropped
  `File`'s OS path via the existing `bridge.pathForFile`) so bytes never pass
  through the renderer; works for large videos.
- Media folder rule: `<dir>/<kebab-stem>-media/` next to the document —
  `docs/BACKLOG.md → docs/backlog-media/` (matches the committed repo
  convention), `DESIGN.md → design-media/`. Applies to any markdown file.
- Drop handling in `DocumentPreview` (markdown kind only):
  - Edit mode (`EditableMarkdownSurface`): capture the caret position from the
    drop point (`caretRangeFromPoint`), copy each image/video via
    `fs:importAsset`, then insert `<img src>` (images) / `<a href>` (videos)
    with `execCommand('insertHTML')` — Turndown converts these to
    `![name](path)` / `[name](path)` through the existing `onInput` sync. The
    link is inserted only after the copy succeeds; failures surface as an
    error toast per file. Buffer stays dirty until the user saves (normal
    edit-mode semantics).
  - Read mode: the drop is swallowed (`stopPropagation` beats the
    window-level open-as-tab handler, which is a bubble-phase listener) and
    an info toast says to enter edit mode.
  - Drops containing no image/video files bubble through unchanged (window
    handler keeps opening them as tabs).
- Extensions recognized: png/jpg/jpeg/gif/webp/svg/avif/heic;
  mov/mp4/m4v/webm/avi/mkv.

## 3. Footer centering + notification popover

- `.shell-sidebar-footer-tools` gets `justify-content: center`; the trailing
  `.grow` spacer in `ShellSidebarFooter.tsx` is removed. All controls are
  already 28×28, so vertical alignment holds. The dead
  `.app-account-trigger` rule (class no longer rendered) is deleted.
- The footer inbox popover currently anchors `left: 0` to the bell's wrapper
  and clips at the panel edge. Fix: the footer becomes the positioning
  context (`.shell-sidebar-footer { position: relative }`,
  `.inbox-wrap { position: static }` in footer scope) and the menu spans the
  footer width (`left/right: var(--sp-2)`, `min-width: 0`), opening upward as
  before — it can no longer clip regardless of where the bell sits.
- The Settings → Interface toggle that hides the bell is untouched; with the
  bell hidden the remaining controls re-center naturally.

## Rejected alternatives

- Base64 write IPC (bytes through renderer memory; size caps) — rejected for
  copy-by-path.
- BACKLOG.md-only special case — rejected; general markdown rule with a
  derived `<stem>-media/` folder is barely more work.
- Dedicated dock panel kind for the backlog — heavier (new panel kind plus
  render branches in three files) with no benefit over the palette command.

## Testing

Manual (no unit-test harness in repo): typecheck + vite build; drop a PNG and
a .mov onto BACKLOG.md in edit mode (file lands in `docs/backlog-media/`,
links insert at caret, image renders in read mode); read-mode drop shows the
hint toast and does not open a tab; palette shows "Backlog" only in projects
with `docs/BACKLOG.md` and opens it; footer renders centered with the bell
shown and hidden; bell popover opens fully inside the sidebar.
