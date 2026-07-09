# Handoff — 2026-07-09 (session ended mid-batch: login switch)

Michael ended the session mid-work. **v0.1.24 shipped earlier today** (glass
top bar, pill tabs, dark-tab contrast, readable rail, rail-hidden default,
ACP auto-connect, codex device-auth removal, chat image blocks). This file is
the exact state of the NEXT batch, which is **in the working tree,
UNCOMMITTED** — verify (smoke) before committing; this repo releases on every
pushed `v*` tag.

## Working tree right now (uncommitted)

| File | Change | Verified? |
|---|---|---|
| `electron/ipc/mcpServer.cjs` | `mcpHttpEntry()` headers: object map → **array of `{name,value}`** (ACP `HttpHeader[]`) | ✅ probe-verified (below) |
| `electron/ipc/acp.cjs` | new `_session()` helper: `session/new`/`session/load` retry **without mcpServers** on `-32602` (graceful degrade → tool-less chat instead of dead thread) | logic-reviewed only |
| `electron/ipc/updateHandler.cjs` | `update:install` now runs `probe()` first + waits (≤180 s) for any newer download to finish before `quitAndInstall` — kills the update→restart→update-again hop during rapid releases | logic-reviewed only |
| `src/styles/shell.css` | active **project-tab 2px hue line removed** (icon carries identity) | CSS-only; stab line still pending (see task 12) |
| `electron/acpwireprobe.mjs` | NEW: the probe that proved the mcpServers bug (below) | is itself the verifier |

## The big find: ACP "Invalid params" on Connect (Claude AND Codex) — task 14

Root cause: `mcpHttpEntry()` sent `headers: { Authorization: 'Bearer …' }`
(object map). The ACP spec's `HttpMcpServer.headers` is an **array of
`{name, value}` pairs**. Both agents reject the whole `session/new` with a
bare `-32602 Invalid params` — this was the "Claude/Codex ACP doesn't work"
bug all along (the auto-connect added in v0.1.24 made it visible on open).

Proof (`node electron/acpwireprobe.mjs`, run 2026-07-09, real agents, this machine):

```
claude + oldObj  → -32602  zod: headers "expected array, received object"
claude + newArr  → SESSION_OK
claude + none    → SESSION_OK
codex  + oldObj  → -32602  serde: "did not match any variant of untagged enum McpServer"
codex  + newArr  → SESSION_OK
codex  + none    → SESSION_OK
```

Notes: (1) Michael's **codex login is actually valid** — SESSION_OK means the
agent made a real session; the "invalid params signing into codex" he saw was
this same Connect failure, not auth. (2) `.mcp.json` written for the Claude
TERMINAL (`--mcp-config`, mcpServer.cjs ~line 294) legitimately keeps the
OBJECT map — two consumers, two shapes; do not "fix" that one.

## Remaining tasks (harness task list #10–14)

**#10 update pill installs latest (code done, in tree).** Root cause:
`quitAndInstall` applies the last COMPLETED download; with releases minutes
apart + the 15-min focus-check rate limit, a late pill click installed a
stale build and immediately grew a new pill. Fix in tree (see table). To
fully verify you'd need two published releases; logic mirrors the existing
`probe()` contract. Renderer pill already renders the interim 'downloading'
state (broadcasts drive it).

**#11 glass mode without full restart (not started — plan).** Transparency is
creation-time, so painted/eco→glass can't mutate the live window. Key
insight: **recreate the WINDOW, not the app** — agents/ptys live in the main
process and already survive window close→reopen on macOS (acpHandler orphan
adoption via `acp:status`; terminalManager keeps ptys; store rehydrates from
sqlite). Plan: extract/reuse `createWindow()` (electron/main.cjs:261), add
IPC `shell:reapply-window` that writes shell-prefs, closes the main window,
and immediately creates a new one with the new creation flags. Renderer:
Settings' "Restart to finish applying" chip (Settings.tsx:230-245,
`bridge.windowMode` mismatch) becomes "Apply now" calling the new IPC.
Also cheap win: glass→painted/eco can apply live TODAY with no window swap
(the solid window is only an optimization; a transparent window can render
painted fine) — only solid→glass truly needs the recreate. Watch out:
`glassActive` (Liquid Glass) has no detach API; irrelevant under recreate.

**#12 tab hue lines (half done).** Project-tab (`.ptab`) 2px line removed in
tree. REMAINING: decide/remove the session-tab line
(`.stab[data-active='true']::before`, shell.css ~line 1044) — Michael said
"top bar" but the same horizontal color exists one level down; icons already
carry the hue (`.stab-icon` / `.ptab-icon`, full hue when active). Michael's
words: "get rid of the horizontal colors, maybe just differentiate the color
with the terminal symbol or something."

**#13 manual Claude terminals + drafts lost on restart (not started — full
trace done).** The user's extra terminal was "New terminal → typed `claude`":
no `singletonKey`, no `boot`, `restart` undefined. Facts from the trace
(Explore agent, file:line verified):
- Terminal ROWS all persist (`sanitizeSliceForPersist` store.ts:1379-1442)
  but `boot` persists only when `restart` is truthy (line ~1388) → the row
  respawns as a bare shell; nothing re-prepares it (App.tsx auto-claude
  effect ~505-541 targets only `singletonKey === 'agent:claude-code'`).
- Drafts: `trackDraft` gate in Terminal.tsx (~481-485) requires
  `singletonKey` matching `/^(agent|wt):/` → plain terminal drafts are never
  recorded. Retype also requires a `--resume|--continue` boot.
- `claudeSessions` is keyed by WORKSPACE (store.ts:1888-1895, hook events
  carry cwd+session_id only) — a second Claude in the same workspace
  clobbers the first's sid; nothing correlates sid→terminal.
Minimal plan (from the trace): (1) parameterize `launchClaude`
(store.ts:1913-1955) to take a singletonKey + sid instead of hard-coded
`'agent:claude-code'` + `claudeSessions[ws]`; (2) add per-terminal
`terminalSessions: Record<terminalId, sessionId>` persisted + pruned like
`termDrafts` (store.ts:1493-1500); (3) in App.tsx claude.onEvent (~391-404)
correlate sid→terminal via `terminalMeta[id].fgProcess === 'claude'`
(store.ts:85, SessionTabs.tsx:94) and at that moment synthesize
`restart:true` + an `agent:claude-code#<termId>` singletonKey + `--resume`
boot for that terminal (an `agent:` prefix makes trackDraft/armDraftRetype
work with ZERO Terminal.tsx changes); (4) generalize the App.tsx auto-claude
effect to re-prepare every persisted `agent:claude-code*` terminal with its
own sid. Verifier pattern: `electron/draftprobe.cjs` (uses
`singletonKey: 'agent:probe'` — the mechanism already generalizes).

**#14 ACP mcpServers shape (code done + probe-verified, in tree).** See "big
find" above. In-app verification once running: open Claude thread → should
auto-connect (v0.1.24 behavior) and actually reach Connected now; same Codex.

## Before committing/pushing

1. `npm run typecheck` (fast; .cjs changes aren't covered by it)
2. `npm run smoke` — MUST pass (asserts bare-strip + rail-hidden contracts)
3. `node electron/acpwireprobe.mjs` — expect the SESSION_OK matrix above
4. Optional `npm run shoot` → eyeball screenshots/session-grid-*.png
5. Commit style: repo uses `area: evocative sentence`; NO AI co-author
   trailers (Michael's global rule). Push to main + `v0.1.25` tag = release.

## Cross-session coordination

Another Claude session was working in this same checkout earlier today
(shipped v0.1.21–v0.1.23, incl. the inbox + cost chips). It pushed and went
quiet before this handoff; `git status` at handoff time = exactly the files
in the table above.
