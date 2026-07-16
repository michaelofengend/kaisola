import type { ClaudeEffort, CodexEffort } from '../store/store'

/** Native wire-value guards shared by the single-session composer and Mesh so
 * both surfaces persist exactly what the provider reported — no translation. */
export const isClaudeEffort = (v: string): v is ClaudeEffort => ['default', 'low', 'medium', 'high', 'xhigh', 'max'].includes(v)
export const isCodexEffort = (v: string): v is CodexEffort => ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].includes(v)
