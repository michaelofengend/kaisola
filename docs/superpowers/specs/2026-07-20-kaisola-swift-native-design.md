# Kaisola → Swift-native — migration design

**Date:** 2026-07-20
**Status:** design (strategy). Each phase below gets its own spec + implementation
plan before it is built.

## Why

Two goals, chosen together:

1. **Native feel + kill Electron memory.** Measured today (installed
   `Kaisola.app`, one window): **~880 MB** RSS — a 375 MB Chromium renderer
   hosting the whole React UI + WebGL glass + xterm + CodeMirror, a 252 MB
   Electron main, a 128 MB GPU helper, a 49 MB utility helper, and the 77 MB
   Node session-broker. Electron pays a **fresh ~350 MB Chromium renderer per
   window**; three project windows is ~1.6 GB. The repo's whole "glass energy
   modes" effort exists because Electron/WebGL is power-hungry.
2. **One shared Swift core across Mac + iPhone.** The companion already holds
   ~2k lines of protocol, crypto, and domain models in Swift. Promoting that to
   a shared package means a feature is written once and ships to both.

**Targets (success metrics):**

| | One window | Each extra window | Cold launch |
|---|---|---|---|
| Today (Electron) | ~880 MB | +~350 MB | ~1–3 s |
| Hybrid native (goal) | **≤ 450 MB** | **+~60 MB** | **≤ 0.6 s** |
| Fully native (goal) | **≤ 250 MB** | **+~40 MB** | **≤ 0.4 s** |

Verified with an analog of the existing `electron/memorycompare.cjs`, plus a
native RSS probe, run on the same demo session.

## Strategy: hybrid strangler → fully native

**Never a big-bang rewrite.** The Electron app is the daily driver and keeps
shipping until the native app is demonstrably better. The native app grows by
*strangling* — it drives the existing, battle-tested Node backends over their
current socket protocols first, then ports each backend and each web view to
Swift one at a time. Every phase ships something usable.

The accelerant: Kaisola's backend is **already split into detached Node
subprocesses talking over sockets** — the durable `session-broker` (node-pty),
the loopback MCP server, and (post-Task-5) the renderer-neutral
`AcpSessionService`. A native shell can speak those same protocols on day one.

## Non-negotiable invariants — *maintain functionality*

These behaviors must survive the migration. They are acceptance criteria on
every phase, and the cutover gate.

### 1. Durable terminal & agent CLI runs survive app update/restart (headline)

**Today:** `electron/session-broker.cjs` runs as a **detached process** (not the
renderer, not the app window). It owns the `node-pty` PTYs and a disk-backed
scrollback spool, exposes a unix-socket protocol (`sessionBrokerClient.cjs`),
and lets a renderer **reattach by `{streamEpoch, byteOffset}` cursor** after the
window or the whole app restarts. So an in-flight `claude` / `codex` run keeps
running while you update Kaisola; the relaunched app reattaches to the live PTY
with continuous scrollback.

**This must not regress.** How native preserves it:

- **Phases 1–4 reuse the *same* Node broker.** The native macOS app reimplements
  only the small *client* (`sessionBrokerClient`) in Swift and talks to the
  identical broker over its existing socket + reattach protocol. Durability is
  literally unchanged because it is the same process.
- **Full-native port (Phase 5)** replaces the Node broker with a **Swift durable
  PTY daemon** — a helper process (launchd-managed login item / `SMAppService`,
  or a detached helper with an XPC endpoint) that owns `forkpty` PTYs + the disk
  spool + the same `{streamEpoch, byteOffset}` reattach protocol and epoch
  semantics. The app connects on launch and reattaches by cursor, identical to
  today. The daemon is versioned independently of the app so an app update never
  kills a running PTY.

**Explicit test (runs every phase):** start a real `claude`/`codex` CLI in a
terminal, trigger an app update/relaunch of the *shell*, confirm the run
continued uninterrupted and the reattached view shows continuous scrollback with
no lost or duplicated bytes.

### 2. The rest of the parity list

Each must reach behavioral parity before cutover:

- **Multi-project windows** with drag **tear-off / recombine** across windows;
  per-project workspace + session sets; **saved-window restore** on relaunch.
- **Agent lifecycle:** ACP Claude/Codex connect, prompt, **mid-turn steer**,
  cancel, **adoption/resume** of an existing session, one-turn serialization,
  provider queue capability, read-only mode, **sensitive-file handling**, the
  cancel watchdog — all exactly as today.
- **Permissions & autonomy:** the pending-permission model, allow-once/reject,
  saved rules, protected globs, autonomy levels — unchanged semantics.
- **Board + attention authority:** the all-project running / needs-you / done
  surface and native notifications.
- **Companion gateway:** the phone-pairing + live-stream host (Noise XX,
  pairing, gateway) keeps working — this already lives partly in Swift and is a
  natural early beneficiary of the shared core.
- **MCP loopback server:** the built-in agent-facing tool server keeps serving
  project bearer capabilities.
- **Visual parity:** the glass / painted / eco look and per-mode energy behavior
  (as native `NSVisualEffectView` blur — cheaper than the WebGL compose it
  replaces), light/dark/solid, the accent system.
- **Keybindings** (rebindable `keymap.json`), **Firebase Google auth**, **git**
  integration, and **document/editor fidelity** (markdown, code, PDF, math,
  diagrams).
- **Auto-update** of the app itself (electron-updater today → Sparkle or the
  native updater), with the durable daemon surviving the swap.

## Architecture

```
KaisolaCore  (one Swift package — shared, macOS + iOS targets)
  ├─ Protocol · Crypto · Domain models      ← promote from the companion (~2k lines, done)
  ├─ Session / agent / projection / board model
  ├─ Backend clients: BrokerClient · AcpClient · McpClient (talk to today's Node services)
  └─ Wire codecs, cursors, reconciliation

Kaisola (macOS)  — new AppKit/SwiftUI target on KaisolaCore
  ├─ Shell        → windows, tabs/tear-off, board, sessions, settings (SwiftUI/AppKit)
  ├─ Terminal     → SwiftTerm (already a dependency), fed by the durable broker
  ├─ Agents/ACP   → Swift JSON-RPC over Process (or the Node ACP service as a bridge first)
  ├─ Auth/model   → FirebaseAuthBackend (Swift, done) + provider REST (URLSession)
  └─ Editor+Docs  → WKWebView hosting today's React first → native later

Kaisola Companion (iOS)  — existing app, re-based onto KaisolaCore

Backends (strangled last):
  session-broker (Node/node-pty)  → Swift durable PTY daemon (XPC/launchd)
  MCP server (Node)               → Swift, or kept as a small subprocess
```

## Fully-native component map (the detail)

The hybrid keeps three non-native things; going fully native ports each. One has
a caveat (mermaid).

| Piece today | Native replacement | Difficulty / notes |
|---|---|---|
| Terminal / node-pty | **SwiftTerm** (already added, `1.15.0`) over a native `forkpty`; durable **Swift PTY daemon** for persistence | Medium — terminal itself proven in the iOS app |
| Code editor (CodeMirror) | **CodeEditSourceEditor** (TextKit 2 + **tree-sitter** highlighting) — adopt, don't build | Medium-high — the biggest piece |
| ACP agents (Node stdio) | Swift `Process` + JSON-RPC over pipes; `AcpSessionService` is the seam | Medium |
| Markdown / code docs | **swift-markdown** → native views; code blocks reuse the editor highlighter | Low-medium |
| PDF | **PDFKit** | Trivial |
| Math (KaTeX) | **SwiftMath** (LaTeX rendering) | Medium |
| Mermaid diagrams | ⚠️ no native lib — render **offscreen WebKit → SVG**, display natively; or drop | The long pole |
| Storage (better-sqlite3) | **GRDB.swift** | Mechanical |
| MCP server | Swift port, **or keep the small Node subprocess** (loopback, on-demand) | Optional / last |
| Model APIs (Anthropic JS SDK) | URLSession REST | Easy |
| Firebase auth | `FirebaseAuthBackend` (Swift) | Done |

**"100% zero-web" is achievable except mermaid**, where a tiny offscreen
render-to-SVG island is the pragmatic answer. The editor is the real work;
adopting CodeEditSourceEditor keeps it tractable.

## Will it be faster/smoother?

Yes, on the things that make an app *feel* fast — **launch, new-window speed,
streaming/scroll smoothness, glass at low GPU cost, battery/thermals, and
staying smooth under load** (the `Terminal.tsx` comments call the transparent
WebGL surface *"the app's dominant cost while an agent streams"*). It will **not**
change agent/model latency (network- and CLI-bound) or make typing in the editor
meaningfully faster than CodeMirror (native wins there are memory, not speed).

## Migration phases

Each phase ships and is independently valuable. **Electron stays the daily driver
until Phase 4 parity; cut over only when the native app is the better daily
driver.** Each phase gets its own spec + writing-plans cycle.

0. **Extract KaisolaCore**; re-base the iOS companion on it (keeps the companion
   green, proves the package boundary).
1. **Native macOS shell spike:** open a project → native **SwiftTerm** terminal
   driven by the **existing Node broker**. Measure launch + RSS. Run the
   *durable-run-survives-restart* test against the same broker. (Proves the feel,
   the code-share, and invariant #1 for free.)
2. **Agents/ACP sessions** native; **Board + session list** in SwiftUI;
   **multi-window + tear-off**.
3. **Editor + doc views** via the **WKWebView bridge** (reuse today's React);
   native↔web messaging; files + git.
4. **Settings, auth, model/provider, MCP, companion gateway** → **daily-driver
   parity**; dogfood; run the full parity checklist.
5. **Full-native port:** the web island (editor→CodeEditSourceEditor,
   math→SwiftMath, mermaid→offscreen-SVG, docs→swift-markdown/PDFKit) and the
   Node backends (broker→**Swift PTY daemon**, ACP→Swift, MCP→Swift or kept);
   **drop Electron**; hit the full-native memory targets.

## Risks & mitigations

- **Editor parity** (CodeMirror is rich) → adopt CodeEditSourceEditor; accept a
  WKWebView phase; port opportunistically.
- **Mermaid** has no native renderer → offscreen-SVG island; acceptable, isolated.
- **Broker persistence across app update** (invariant #1) → reuse the proven Node
  broker through Phase 4; the Phase-5 Swift daemon mirrors its exact protocol and
  is version-independent of the app; the explicit restart test gates it.
- **Feature-parity drift** → Electron keeps shipping; a written parity checklist
  gates cutover; no cutover until native is the better daily driver.
- **Scope** → decomposed into phase-specs; this doc is strategy only.

## Out of scope here

Windows/Linux native (Electron already handles cross-platform; native is
macOS-first). Any single mega-implementation — the next step is a detailed spec +
plan for **Phase 0 (KaisolaCore) + the Phase 1 terminal spike**, which together
prove the architecture, the code-share, the memory win, and the durable-run
invariant with the least risk.
