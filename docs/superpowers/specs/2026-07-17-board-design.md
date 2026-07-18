# Kaisola Board — desktop homepage design

**Date:** 2026-07-17 · synthesized from a GPT-5.6 sol design-collab proposal
(session 019f733a) and Claude's design pass · reference: Codex cloud board
screenshot in `docs/backlog-media/Screenshot 2026-07-17 at 12.43.39 AM.png`

## Thesis

A live operations cockpit, not a kanban clone. The Board answers "what needs
me right now, and what is moving" across every project, then routes to the
exact owning session in one click. Cards move between lanes automatically;
the user never drags.

## Placement

- Shell-level pinned first tab in the main window, before project tabs, with
  a quiet 2×2-grid icon and an amber badge showing only the needs-you count.
- Not a `ProjectTab`: selecting Board preserves the active project and every
  project's session layout. Project rails/canvas hide while Board is active.
- A fresh main window opens to Board; restored windows keep their last surface.
- Detached project windows never show Board.

## Data

Render the **same renderer-built companion projection the phone consumes**
(`buildCompanionProjection` in `src/lib/companionProjection.ts`) — one
normalization for desktop Board, mobile Now, and the attention authority.
No new IPC in v1.

## Layout

Header: actionable summary line — "2 need you · 4 running · 9 done across 6
projects" — plus a Live/stale indicator. No hero, no orb.

Three persistent lanes in lifecycle order, each with sticky header, count,
own scroll; empty lanes stay visible:

- **Running** (~1fr) — newest first, stable order (no heartbeat reshuffling).
- **Needs You** (~1.2fr, amber-foregrounded) — critical → warning → info,
  then longest-waiting first; failures land here, never in Done.
- **Done** (~0.85fr, denser) — newest completion first.

Below ~900px: one stacked column (Running / Needs You / Done), never a
miniature horizontal kanban.

## Cards

Common: status marker, **project name first**, session title, one clamped
summary line, provider/kind, relative time. Never raw transcripts.

- Running — olive pulse + the **signature: a live one-line monospace activity
  preview** of the session's latest output (from the projection's activity
  fields), quietly updating with a soft olive caret pulse. Click → open the
  exact session (switch project, focus session, front the owning window).
- Needs You — amber (red for failed); attention kind label (Permission,
  Question, Review, Blocked, Failed); prominent age; `+N more` collapses
  multiple events on one session into the highest-severity card; contextual
  CTA stays visible (Review request / Answer / Inspect failure).
- Done — static green check, outcome summary, shorter card. Click reopens.

Idle sessions stay off the Board. Attention without a session becomes a
standalone Needs You card routing to the ledger/inbox item.

## Motion & conduct

- Lane transitions 180–220 ms, restrained; respect Reduce Motion.
- Never steal keyboard focus; never reorder a hovered/focused card underneath
  the pointer.
- Opening a session marks its attention observed (existing behavior).

## Deliberately out of v1

Filter dropdowns and search (single user, few projects), list view, Hide
done, drag anything, per-lane menus, board in pop-out windows.

## Verification

Typecheck, layout probe, full smoke, plus a ui-screenshot-analyst pass on the
rendered Board in light/dark/solid/glass.
