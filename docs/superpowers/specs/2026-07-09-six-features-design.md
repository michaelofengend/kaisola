# Six-feature round: quick wins + endorsed trio, Settings-gated

**Date:** 2026-07-09 · **Status:** approved scope (Michael: "do all three S-tier quick
wins + the top three you endorse, keep things light and customizable in settings")

## Principles

Every new behavior that changes what's on screen gets a Settings toggle (new
**Interface** section) + a `settings.json` key, mirroring the `automationsEnabled`
flag pattern (`store.ts:934/1673/3391/484`). Defaults favor the feature ON except
where noted. Toggles are On/Off Dropdowns (the codebase has no Switch component).

## 1. AGENTS.md template action (S)

"New AGENTS.md" item in the workspace rail's folder context menu
(`WorkspaceRail.tsx:520`, beside "New file…"; root + dir rows). Writes a
human-editable template via `bridge.fs.write` then `requestFile(path,'edit',
{pinned:true})` — the `openConfigFile` pattern. Never auto-generated (research:
LLM-generated context files hurt task success). Hidden when AGENTS.md already
exists in that folder (menu item switches to "Open AGENTS.md"). No toggle — it's
a menu action, inert unless used.

## 2. Numbered blank tabs (S)

`newProject` (`store.ts:3845`) assigns `title: 'New Project N'` at creation when
other blank (workspace-less, untitled) tabs exist — first blank tab stays plain
"New Project". Persisted like any title; rename still wins. No toggle (pure
disambiguation).

## 3. Word-level diff highlighting (S)

`GitPanel`'s MergeView already intra-line-highlights (`highlightChanges: true`) —
untouched. Work targets `ResearchDiff.tsx` only:
- **Entity branch** (`change.before`/`change.after` pairs): tokenize both into
  words, LCS word-diff (small hand-rolled differ, no dep), wrap changed words in
  `<mark class="rdiff-word">` inside the existing `rdiff-line-del/add` rows.
- **File-patch branch** (unified patch string): pair adjacent `-`/`+` runs within
  a hunk (classic pairing: i-th deleted line ↔ i-th added line) and word-diff
  each pair; unpaired lines render as today.
- Toggle: `wordDiffs` (default ON). OFF renders exactly today's output.

## 4. Per-session $ cost chip (S–M)

Data source (verified): Claude terminal sessions have per-session JSONL
transcripts under `<configDir>/projects/*/<sessionId>.jsonl` with
`message.usage` + `message.model` per assistant message; the session id is known
(`claudeSessions` map / hooks `sessionId`). ACP frames + hooks carry no usage →
ACP threads get NO chip in v1 (absent data, not a fake estimate).
- Main: `usage:claudeSession` IPC in `usageHandler.cjs` — `{ configDir?,
  sessionId }` → per-model token sums `{ model, input, output, cacheRead,
  cacheWrite }[]` (reuse the existing JSONL walker + dedupe).
- Renderer: a quiet `$0.42` chip on the session-card head (terminal cards whose
  singleton is `agent:claude-code` / whose sessionId is known), title-attr
  breakdown per model + token classes. Cost = builtin per-Mtok rate table for
  known model families; unknown models show tokens only. Refresh on Claude
  hook `Stop` events + card mount (no polling).
- Toggle: `showCosts` (default ON — Amp ships it on by default and it's the
  point of the feature). settings.json: `"showCosts"`.

## 5. Hunk-level accept/reject on Proposals (M)

Scope: entity changes with BOTH `before` and `after` strings (kind 'update') in
non-file proposals. File-patch (worktree) proposals stay whole-merge.
- Line-diff `before`→`after` into hunks (same hand-rolled differ, line mode).
- ProposalCard grows per-hunk checkboxes (default all checked) on such changes,
  replacing the `ProposalCard.tsx:72` disabled "Phase 2" stub.
- Approving with some hunks unchecked derives `after' = before + checked hunks
  only`, patches the change (`change.after = after'`), applies via the existing
  `applyProposal` path, and marks the proposal `'edited'` (the status already
  exists, unused — this is its purpose). All-checked = today's `'approved'`.
- The human-gate invariant is untouched: a partial accept is just a smaller
  proposal applied through the same gate.
- No toggle (it's an affordance on a gated surface, invisible until used).

## 6. Cross-project "needs you" inbox (M)

A bell button in `.tabstrip-tools` with a count badge, opening a dropdown that
rolls up, across ALL project tabs:
- active project: sessions in `needsYou` + live `pendingPermissions`
- background projects: `projectSlices[pid].pendingPermissions` + tabs whose
  `activity === 'needs-you' | 'failed'`
- global: ledger tasks with status `review` or `blocked`
Rows: icon + project name + session/task label + age. Click → `switchProject(pid)`
(badge auto-clears) — session-level reveal within the active project uses the
existing dock reveal actions. Empty state: the button hides entirely when count
is 0 (light chrome, no dead bell).
- Toggle: `inbox` (default ON). settings.json: `"inbox"`.

## 7. Settings expansion — new "Interface" section

New `SECTIONS` entry `{ id: 'interface' }` between general and terminal, holding:
- Word-level diff highlights (On/Off) — `wordDiffs`
- Session cost chips (On/Off) — `showCosts`
- Cross-project inbox (On/Off) — `inbox`
- Restore CLI drafts after restart (On/Off) — `draftRestore` (gates the v0.1.20
  retype behavior; tracking is harmless and stays on)
- Wallpaper-tinted chrome (On/Off) — `wallpaperTint` (gates glassWash retinting;
  OFF keeps the theme-constant veils)
All five: store booleans (mirror `automationsEnabled`), `GLOBAL_KEYS`,
`applySettings` + `SETTINGS_TEMPLATE` lines. Existing rows stay where they are.

## Verification

- Word-diff: unit-shaped probe (executeJavaScript against the differ export) +
  screenshot of a ResearchDiff with word marks; toggle OFF renders legacy DOM.
- Cost chip: probe seeds a fake transcript JSONL in a temp configDir, invokes
  `usage:claudeSession`, asserts sums; UI chip presence gated by toggle.
- Hunk accept: probe builds a two-hunk proposal in the store, unchecks one hunk,
  approves, asserts derived entity text + status 'edited'.
- Inbox: probe seeds needsYou + a background slice pendingPermission + a ledger
  review task, asserts rollup count + jump switches project.
- Tab numbering: create 3 blank tabs → labels 'New Project', 'New Project 2', 3.
- AGENTS.md: menu action writes template + opens pinned; existing file → opens.
- Full smoke PASS (extend PLUS/GLASS checks only if they trip); release.

## Out of scope (this round)

ACP-thread cost chips (no usage data in frames yet); per-LINE (sub-hunk) accept;
inbox OS notifications; AGENTS.md auto-generation.
