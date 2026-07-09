/**
 * The AGENTS.md scaffold — the cross-tool agent-context standard (agents.md,
 * Linux Foundation) read natively by Claude Code, Codex, Cursor, Gemini CLI,
 * Aider and friends. Deliberately a TEMPLATE, never auto-generated: research
 * shows LLM-written context files underperform human-written ones, so Kaisola
 * hands you the skeleton and stays out of the prose.
 */
export const AGENTS_TEMPLATE = `# AGENTS.md

<!-- Read by every coding agent that opens this folder (Claude Code, Codex,
     Cursor, Gemini CLI, Aider, …). Keep it short and factual — this file is
     context the agent trusts, so stale claims do real damage. -->

## What this project is

<!-- One or two sentences. What does it do, who is it for? -->

## Commands

<!-- The commands an agent should actually use — build, test, lint, run.
     Example:
- \`npm run build\` — typecheck + bundle
- \`npm test\` — run the suite (must pass before any commit) -->

## Conventions

<!-- The rules a new contributor gets told in review. Naming, structure,
     error handling, what NOT to touch. -->

## Gotchas

<!-- The things that waste an afternoon: flaky tests, generated files,
     environment quirks, load-bearing hacks. -->
`
