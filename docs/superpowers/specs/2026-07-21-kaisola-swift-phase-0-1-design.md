# Kaisola Swift-native Phase 0/1 — shared core and terminal proof

**Date:** 2026-07-21
**Status:** approved for implementation
**Builds on:** `2026-07-20-kaisola-swift-native-design.md`

## Outcome

Phase 0 establishes one versioned Swift core shared by the existing iPhone app
and the new macOS app. Phase 1 then ships a signed native macOS application that
can observe the exact durable terminal sessions owned by today's detached Node
broker without taking control away from the Electron daily driver.

This is a strangler migration. Electron remains fully usable and releasable
until the native app passes explicit parity, durability, packaging, and resource
gates. Nothing in Phase 0 or Phase 1 may alter the lifecycle of a running PTY.

## Decisions

The strategy's four open decisions are resolved as follows.

### A — separate control plane

Use a standalone authenticated Node control-plane host for ACP, MCP, and the
Companion gateway. The durable session broker remains a separate,
independently-versioned process and is never folded into that host.

The control-plane extraction starts in Phase 2. Phase 1 talks only to the
existing session broker.

### B — direct distribution

Ship the macOS app outside the Mac App Store as a notarized Developer ID build,
initially without App Sandbox. Kaisola must open arbitrary user-selected repos
and launch shells, git, adapters, compilers, and agent CLIs. Those requirements
are a poor match for an App-Sandbox-first architecture.

Non-sandboxed does not mean unbounded trust. Local helpers must be per-user,
authenticate every client, use private sockets and files, validate peer code
signatures where the platform permits it, and expose the smallest method set
required by the caller. A system LaunchDaemon is forbidden.

### C — separate stores and one-way import

Electron and native use separate databases while both ship. Native may perform
an idempotent one-way import from an Electron snapshot. An immutable import
ledger records the source-store identity and schema, snapshot hash, import
revision, and destination native schema. It must never write Electron's live
database.

At daily-driver cutover, native becomes the write owner. The Electron store is
retained for rollback until the release is proven.

### D — dual-broker drain

The eventual Swift PTY daemon does not attempt to receive live PTY file
descriptors from Node. During Phase 5, existing sessions remain on the Node
broker until they exit; new sessions may be routed to the Swift daemon. The Node
broker is removed only after its live-session count reaches zero and rollback
requirements are satisfied.

Every terminal record created during the drain carries explicit Node-or-Swift
backend provenance. Routing must never be inferred from a terminal id,
`streamEpoch`, current process availability, or whichever daemon answers first.

## Scope correction: no native desktop Board

The desktop Board was retired on 2026-07-20 after real use showed that it
duplicated the project/window workflow. It is not a native parity requirement
and must not return in Phase 2. Native preserves projects, windows, sessions,
needs-you state, completion notifications, and the iPhone's lightweight grouped
activity views.

The existing `CompanionBoard` wire fields remain Codable during protocol
coexistence so semantic round-trip fixtures remain possible, but no native
desktop UI target may consume or render them. Removing them is a separate
versioned protocol change, not part of Phase 0.

## Process boundaries through Phase 4

```text
Kaisola.app (Swift/AppKit + SwiftUI)
  |
  +-- KaisolaCore (Swift package, also used by iPhone)
  |
  +-- private authenticated broker socket
  |     `-- session-broker (Node + node-pty, detached, PTY owner)
  |
  `-- Phase 2 authenticated control socket
        `-- control-plane host (Node: ACP + MCP + Companion)

Kaisola Electron (daily driver during coexistence)
  +-- uses the same durable broker
  `-- retains existing UI/state ownership until each slice cuts over
```

The session broker and control-plane host have different durability and update
rules. Updating the UI may restart the control plane, but it must not replace or
terminate a broker that still owns live terminals.

## Phase 0 — KaisolaCore

### Package boundaries

Create a local Swift package under `native/KaisolaCore` with narrow targets:

- **KaisolaCore** — platform-neutral domain models, protocol envelopes,
  canonical JSON, cryptographic primitives, pairing records, replay cursors,
  and projection reconciliation.
- **KaisolaBrokerProtocol** — macOS-capable models and codecs for the detached
  broker contract. It must not create or own terminals.
- **KaisolaTestSupport** — fixture discovery and deterministic test helpers.

The iPhone app must not depend on `KaisolaBrokerProtocol`. UIKit, SwiftUI,
Firebase browser presentation, LocalAuthentication prompts, Keychain storage,
Bonjour lifecycle, and app lifecycle coordination remain platform adapters in
their respective application targets.

### Source-of-truth rule

No language implementation is the sole wire authority. Versioned JSON fixtures
and explicit constants form the contract. JavaScript and Swift both decode,
validate, and reproduce those fixtures.

The existing `electron/companion/fixtures` files remain at their current path
during Phase 0 so the shipping Node and iPhone test suites do not break. A later
mechanical move may place them under a top-level `protocol/fixtures` directory
with compatibility forwarding.

### API migration

Pure Swift types move into the package rather than being copied. The iPhone app
imports `KaisolaCore`; compatibility re-exports may keep application files
small during the transition, but there must be one compiled definition of each
migrated type.

The first extraction boundary is:

- `JSONValue` and canonical JSON;
- Companion envelope, body, capability, cursor, and event/command models;
- domain projection models;
- cryptographic primitives, Noise XX, secure frame channel, pairing models;
- pure length framing.

Platform identity persistence and control authorization stay in the iPhone app.
The pure identity/key-record models may move while their Keychain adapter stays.

### Phase 0 exit gates

- `swift build` and `swift test` pass for the package.
- Existing Node companion protocol/crypto tests remain green.
- The generated iOS project consumes the local package and does not compile
  duplicate migrated sources.
- iOS simulator build and tests pass in Debug and a Release build succeeds.
- Crypto vectors, strict unknown-field rejection, frame limits, identifier
  validation, and projection fixtures produce the same outcomes in both
  languages.
- Pairing, reconnect, terminal replay/control, and Kaisola Link behavior remain
  unchanged on iPhone.

## Phase 1 — native terminal proof

### Native shell

Create `native/KaisolaMac` as an XcodeGen-managed macOS application. AppKit owns
application/window lifecycle, menus, commands, focus, restoration, and native
drag/drop. SwiftUI renders the initial shell and SwiftTerm terminal surface.

Use a distinct development bundle identifier and native data directory so the
spike cannot overwrite Electron state. Packaged preview builds may later adopt
the production identifier only through an explicit migration release.

Broker discovery is a read-only compatibility adapter, not native-state
storage. It reproduces Electron's installed legacy profile precedence across
`pasola`, `Pasola`, and `Kiasola` (and the explicit development profile) so a
live broker is found in place. Candidate directories, metadata, and socket
paths must pass ownership, mode, regular-file, and symlink-rejection checks.

The initial UI contains only:

- a compact project/session source list;
- current connection and read-only state;
- one SwiftTerm terminal viewer;
- reconnect/reload affordances and useful empty/error states;
- native light/dark appearance, selection, copy, search, and accessibility.

It does not contain the editor, document renderer, settings clone, ACP controls,
or the retired Board.

### Broker wire client

The Swift client mirrors the current broker contract:

- protocol `2`, security epoch `1`;
- authenticated newline-delimited JSON over a private Unix socket;
- a maximum legal frame of 56 MiB;
- incremental decoding with bounded memory and explicit backpressure;
- exact project capability on observer subscriptions;
- a typed observer API limited to `broker.status`, `terminal.list`,
  `terminal.diagnostics`, `terminal.subscribe`, and `terminal.unsubscribe`;
- reconnect via `streamEpoch` and `afterOffset`;
- explicit epoch-mismatch, cursor-ahead, and retained-history-gap handling.

The observer hello advertises its access role. New brokers enforce the same
allowlist server-side; old protocol-2 brokers remain usable through the native
client's unrepresentable-mutation policy. Raw method construction stays private
to the transport and tests prove every emitted method is allowlisted.

Phase 1 must never call `terminal.attach`, `terminal.create`, `terminal.write`,
`terminal.resize`, `terminal.signal`, `terminal.kill`, or `terminal.release`.
Those calls either transfer ownership or mutate the terminal and are outside the
observe-only proof.

### Ownership and compatibility

Electron remains the terminal controller. Native is an observer and may run at
the same time without changing owner, last owner, visibility, release timers,
PTY dimensions, or process lifetime.

The broker currently requires exact protocol equality. Any later
snapshot-plus-subscribe or primary ownership work must introduce a documented
N/N+1 compatibility policy. Required combinations are:

- old Electron client with old running broker;
- new native client with old running broker;
- new Electron client with old running broker after an app update;
- new clients with a newly launched broker;
- rollback client with a newer compatible broker.

An incompatible live broker is never killed automatically merely to satisfy a
new UI build.

### Broker packaging

Development may connect to the broker launched by Electron. A shippable Phase 1
must bundle or install a signed standalone Node runtime plus the exact
`node-pty` native-module closure. The broker is registered as a per-user helper
and stores its private socket metadata, token, spool, and diagnostics with mode
`0700` directories and `0600` files/sockets.

Release evidence includes a manifest of every nested executable and native
module, hardened-runtime entitlements and designated requirements, strict deep
signature verification, Gatekeeper assessment, notarization and stapling,
translocation-safe launch, and rejection after a bundled helper is altered.

The updater replaces the UI application without replacing a running broker.
Helper upgrade is deferred until no live sessions remain or the running helper
already satisfies the client's compatibility range.

### Phase 1 exit gates

- Signed and notarized packaged native build launches without Electron.
- The app discovers or safely starts the broker without hard-coded developer
  paths.
- A real Claude and a real Codex CLI remain running across an actual app update;
  retained output is neither duplicated nor silently lost.
- Reconnect works after UI crash, socket loss/republication, sleep/wake, network
  irrelevance, and multiple native windows.
- Stress tests cover legal 56 MiB frames, at least 8 MiB terminal snapshots,
  fast sustained output, split UTF-8, ANSI mode changes, truncation markers,
  slow consumers, and broker backpressure.
- SwiftTerm validation covers keyboard/IME behavior needed for future control,
  accessibility, copy/search, mouse/focus modes, large scrollback, resize
  behavior, appearance, and streaming performance.
- The same physical-footprint harness measures Electron and native workloads.
  Baseline and target never use different metric families.

## Measurement workloads

Record median and p95 for cold and warm launches with:

1. one restored project window and one idle terminal;
2. one window with a continuously streaming terminal;
3. three restored project windows;
4. an already-running broker versus a freshly started broker;
5. any offscreen WebKit or Node control-plane helpers counted in the app total.

Measure physical footprint, launch-to-interactive time, CPU, frame pacing,
terminal throughput, energy impact, and sustained-stream battery use. The old
~880 MB summed-RSS observation is context only until remeasured by this method.

## Rollback

- Phase 0 rollback points the iPhone project back to its previous source layout;
  no persisted data changes.
- Phase 1 rollback removes the native app while leaving Electron and the running
  Node broker untouched.
- Package, broker, and state schema versions are recorded independently.
- No migration deletes the prior Electron store or terminal spool.

## Definition of complete

Phase 0 is complete when iPhone ships from the shared package with no behavioral
regression. Phase 1 is complete when a packaged native terminal observer proves
the process boundary, update durability, SwiftTerm quality, and resource win.
Neither phase declares the native app the daily driver.
