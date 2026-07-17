# Codex agent roles — design

**Date:** 2026-07-17
**Status:** Approved (pending spec review)

## Goal

Set up a global multi-role agent so GPT-5.6 sol (via the openai-codex Claude Code
plugin) acts as **plan reviewer**, **default executor**, **code reviewer** (alongside
Claude's own `/code-review`), and **front-end design collaborator** in every project.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Claude review side | Reuse the built-in `/code-review` skill; no duplicate Claude reviewer agent. Dual review = Codex review + `/code-review`, merged by the main thread. |
| Plan review trigger | Proactive: dispatched automatically after any spec/plan doc is written, before the user review gate. |
| Executor role | Codex is the **default executor** for planned implementation tasks; Claude implements only trivial edits and always verifies results. |
| Scope | Global — `~/.claude/agents/` + `~/.claude/CLAUDE.md`. |
| Shape | One multi-role agent file (`codex.md`) with explicit `MODE:` dispatch, not three separate agents. |
| Front-end design | Fable 5 and GPT-5.6 sol collaborate: Claude drafts direction (frontend-design skill), Codex independently proposes/critiques, main thread synthesizes. |

## Files

1. **`~/.claude/agents/codex.md`** — new multi-role agent (created by this work).
2. **`~/.claude/CLAUDE.md`** — append a "Model role split (Claude ⇄ Codex)" section.

## Agent design (`~/.claude/agents/codex.md`)

Thin Bash-only forwarding wrapper around the plugin's `codex-companion.mjs`,
modeled on the plugin's own `codex-rescue` agent.

**Frontmatter:** `name: codex`, `model: sonnet` (wrapper only shapes and forwards
prompts), `tools: Bash`. Description advertises the four modes and proactive
checkpoints so the main thread dispatches it automatically.

**Path resolution:** `${CLAUDE_PLUGIN_ROOT}` does not resolve outside plugin
components, and the plugin cache path is versioned. The agent resolves the script
dynamically:

```bash
COMPANION=$(ls -d "$HOME/.claude/plugins/cache/openai-codex/codex/"*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
```

**Model/effort:** never pass `--model`/`--effort`; `~/.codex/config.toml` already
defaults to `gpt-5.6-sol` at `max` reasoning effort.

**Modes** (dispatch prompt starts with a `MODE:` line; if absent, infer: mentions
reviewing a plan/spec doc → `plan-review`; asks to implement/fix/build →
`execute`; asks to review code/a diff/a branch → `code-review`; asks about visual
design, layout, or UI direction → `design-collab`):

- `MODE: plan-review` — one read-only call: `task` (no `--write`) instructing Codex
  to read the given spec/plan file and critique gaps, risks, ordering problems,
  simpler alternatives, and ambiguity — as appended findings, never a rewrite —
  ending with `VERDICT: APPROVED` or `VERDICT: REVISE`. Re-reviews after revisions
  add `--resume-last`; the orchestrator caps iteration at 2 revision rounds before
  handing back to the user. Output returned verbatim.
- `MODE: execute` — `task --write`; add `--background` for long/open-ended jobs,
  `--resume-last` for continuations ("keep going", "apply the fix").
- `MODE: code-review` — `review` by default; `adversarial-review [focus]` when the
  dispatch asks for it **or when Codex itself wrote the code under review**.
- `MODE: design-collab` — read-only `task` asking Codex for an independent
  front-end design proposal or critique (visual direction, layout, typography,
  interaction) for a named surface/component.

**Conduct rules** (inherited from the plugin contract): one companion call per
dispatch; no repo inspection or independent analysis beyond shaping the forwarded
prompt; return stdout verbatim.

**Error handling (deviation from plugin):** on unresolved path or failed call,
return an explicit failure note (e.g. "codex companion unavailable: <reason>")
instead of returning nothing, so the orchestrating thread knows to fall back to
doing the work itself and to tell the user.

## Orchestration section (`~/.claude/CLAUDE.md`)

Appended section instructing the main Claude thread:

- **Planning:** Claude brainstorms and writes specs/plans. After writing one and
  before the user review gate, dispatch `codex` with `MODE: plan-review` + doc
  path; present its findings alongside Claude's own assessment.
- **Execution:** dispatch `codex` `MODE: execute` by default for planned
  implementation tasks; Claude implements directly only for trivial edits, and
  always verifies results itself (tests / verify skill).
- **Review:** after implementation, run dual review — `codex` `MODE: code-review`
  **and** Claude's `/code-review`; merge, dedupe, and attribute findings.
- **Front-end design:** collaborate — Claude drafts direction with the
  frontend-design skill, dispatches `codex` `MODE: design-collab` for an
  independent take, then synthesizes both before implementing.
- **Proportionality:** skip Codex dispatches for trivial/low-risk changes (simple
  1–5 file features, isolated bugfixes, throwaway prototypes); use the full
  cross-model loop when error cost is high (auth, payments, data, migrations,
  long implementations).
- **Fallback:** if the plugin/agent is unavailable, Claude does the work itself and
  says so.

## Research notes (2026-07-17)

Ecosystem survey confirmed the design matches the dominant cross-model pattern
("the writer doesn't review, the reviewer doesn't write"; planner/executor/
reviewer splits across models with non-overlapping training biases). Adopted from
the survey: the `VERDICT:` convention with a bounded revise→re-review loop
(SmartScope), findings-not-rewrites plan review (claude-codex.fr), and the
proportionality rule. Considered and skipped: stop-hook review gates (plugin
already offers `/codex:setup --enable-review-gate`), MCP re-registration, and
JSON pipeline frameworks (overhead without added value here).

## Testing

1. Verify the path glob resolves to the companion script.
2. One end-to-end dispatch: `MODE: plan-review` against
   `docs/superpowers/specs/2026-07-17-mobile-companion-design.md`, confirming the
   agent forwards correctly and returns Codex output.

## Out of scope

- No changes to the plugin itself, the review gate, or `codex-rescue`.
- No per-project overrides (the global agent can be shadowed later by a
  project-level `.claude/agents/codex.md` if ever needed).
