# Cross-provider agent orchestration research — 2026-07-13

## Decision

Kaisola Mesh should remain a **manager-owned, bounded workflow**, not become an
unstructured group chat. The coordinator owns the mission, state machine,
permissions, retries, and final user-visible result. Provider sessions remain
independent workers with explicit inputs and terminal receipts.

The production protocol is:

1. independent scouting;
2. one bounded alignment round;
3. a human-approved role contract;
4. isolated worktree execution;
5. cross-review of exact commit SHAs;
6. single-owner integration and verification.

That shape preserves the main benefit of multi-agent systems—parallel,
independent investigation—without paying for open-ended model-to-model chatter
or allowing concurrent edits to the same checkout.

## What the primary sources imply

### Keep one conversation owner

OpenAI distinguishes manager-style orchestration, where one agent owns the
final answer, from handoffs, where a specialist takes over the conversation.
Mesh is a manager-style product: no hidden worker should become the owner of the
user's session, permissions, or durable state.

Anthropic's production research system likewise uses a lead agent that creates
parallel subagents and synthesizes their results. Its engineering report says
this works best for breadth-first, parallelizable work, usually with roughly
three to five subagents, while tightly coupled coding work is a weaker fit and
multi-agent token use can be dramatically higher. This supports Kaisola's
participant cap and its ownership-contract/worktree boundaries.

Sources:

- [OpenAI: Orchestrating multiple agents](https://developers.openai.com/api/docs/guides/agents/orchestration)
- [Anthropic: How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)

### Treat a run as a durable state machine

A streamed partial answer is not completion. Every dispatched stage needs an
idempotency/attempt ID, exact targets and prompts, provider terminal status,
timestamps, and a final text receipt. Promotion must require matching terminal
receipts from every target.

Cancellation is a state transition, not deletion. OpenAI's background-mode
guidance exposes explicit cancellation and cursor-based stream resumption;
Gemini's Interactions API exposes stored interaction IDs, observable steps, and
background execution. ACP now has stable session resume and close methods.
Kaisola should normalize those provider differences behind its own journal.

Sources:

- [OpenAI: Background mode](https://developers.openai.com/api/docs/guides/background)
- [Gemini: Interactions API](https://ai.google.dev/gemini-api/docs/get-started)
- [ACP protocol updates](https://agentclientprotocol.com/updates)

### Parallelize across sessions, serialize within one session

OpenAI's WebSocket mode permits only one in-flight response on a connection and
recommends multiple connections for true parallel work. The same conservative
rule fits ACP adapters: one prompt stream per provider session, multiple
independent sessions across Mesh participants, and a bounded coordinator fanout.

Concurrency should also respect provider backpressure. Anthropic documents
token-bucket limits, `retry-after`, separate model limit pools, and cache-aware
input-token accounting. A future direct-API scheduler should therefore maintain
per-provider queues and retry budgets rather than applying one global interval.
For today's CLI/ACP integration, bounded participants and one in-flight prompt
per session are the safe common denominator.

Sources:

- [OpenAI: WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode)
- [Anthropic: Rate limits](https://platform.claude.com/docs/en/api/rate-limits)
- [Anthropic: API errors and retry behavior](https://platform.claude.com/docs/en/api/errors)

### Share artifacts, not full conversational transcripts

Worker-to-worker context should be an explicit packet: mission, accepted role
contract, peer result, changed paths, exact commit SHA, and acceptance tests.
This keeps prompts auditable and prevents quadratic free-chat growth. For large
artifacts, pass a path or content address and a bounded summary instead of
copying the entire transcript into every worker.

Stable instructions and shared material should precede dynamic member-specific
content. OpenAI and Gemini both recommend stable common prefixes to improve
cache reuse. Anthropic's cache-aware rate accounting makes this an important
throughput optimization as well as a cost optimization.

Sources:

- [OpenAI: Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- [Gemini: Context caching](https://ai.google.dev/gemini-api/docs/caching)

### Preserve provider-native state and controls

Do not flatten model, effort, thinking, and session semantics into a fictional
universal control. Capabilities must be discovered from the adapter and stored
with the participant. Anthropic's effort setting explicitly trades thoroughness
for speed/token use; Gemini stateful interactions use `previous_interaction_id`
and its stateless flows require reasoning signatures to be returned intact.
Kaisola should let the provider own those details while presenting a consistent
control surface.

Sources:

- [Anthropic: Effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Gemini: Thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures)

### Use interoperability protocols at their real maturity level

ACP is the right local client-to-coding-agent transport and now has stable
resume/close lifecycle methods. MCP remains the tool/context plane; its task
facility is still experimental, so Mesh must not make durable execution depend
on it. A2A supplies useful concepts—agent cards, tasks, messages, artifacts,
status—but is an optional remote-agent boundary, not a replacement for the
local coordinator.

Sources:

- [Model Context Protocol: Tasks](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)
- [A2A key concepts](https://a2a-protocol.org/latest/topics/key-concepts/)
- [A2A specification](https://github.com/a2aproject/A2A/blob/main/docs/specification.md)

## Applied in this release

- Durable stage attempt IDs, prompts, targets, statuses, pause state, and exact
  reviewed commits.
- Terminal provider receipts containing success/failure, stop reason, timing,
  and the final response text.
- A stream-completion barrier so the final token is committed before the
  terminal receipt resolves.
- Stop that snapshots completed work, cancels only unfinished workers, and
  keeps the team recoverable across renderer/app restarts.
- Continue that waits for cooperative cancellation, reconnects if necessary,
  and retries only unfinished participants.
- Real per-member status, aggregated permission requests, and visible errors.
- Provider-native model and Claude effort controls in the Mesh roster.
- A six-participant bound and bounded shared-result packets.
- Isolated worktrees, cross-review, and integration of the exact reviewed SHA;
  post-review drift is rejected.
- Stable ACP resume/close support with legacy load compatibility.
- Workspace-contained ACP file callbacks, symlink/traversal checks, file/frame
  limits, request deadlines, and sender-bound permission replies.
- Adaptive adapter leases: warm during work and permission waits; park safely at
  paused, approval, and complete gates.

## Next architecture investments

1. Add provider-aware backoff telemetry once adapters expose consistent rate
   limit signals through ACP.
2. Move large peer artifacts to content-addressed packets so a six-member Mesh
   does not duplicate long text across every alignment/review prompt.
3. Add a coordinator event log export containing attempts, receipts,
   permissions, commits, and timing for debugging and evaluation.
4. Build task-shape routing: use parallel Mesh only when assignments can be
   made orthogonal; keep tightly coupled single-file work with one agent.
5. Evaluate remote A2A workers only behind the same journal and permission
   model; do not create a second orchestration truth source.
