/**
 * A small, dependency-free LCS differ shared by two features:
 *  - word-level highlights in ResearchDiff (which exact words changed)
 *  - hunk splitting + partial application for Proposal accept/reject
 * Inputs beyond the DP cap fall back to "everything changed" — correctness
 * degrades to today's whole-line rendering, never to wrong output.
 */

const DP_CAP = 400

/** Tokenize into words KEEPING whitespace separators (so marks don't reflow). */
export const words = (s: string): string[] => s.split(/(\s+)/).filter((t) => t !== '')

/** LCS keep-flags: true = token survives unchanged on that side. */
function lcsKeep(a: string[], b: string[]): { a: boolean[]; b: boolean[] } {
  const n = a.length
  const m = b.length
  if (n > DP_CAP || m > DP_CAP) return { a: a.map(() => false), b: b.map(() => false) }
  // classic O(n·m) length table, then walk back
  const L: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      L[i][j] = a[i] === b[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1])
    }
  }
  const keepA = a.map(() => false)
  const keepB = b.map(() => false)
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) { keepA[i] = true; keepB[j] = true; i++; j++ }
    else if (L[i + 1][j] >= L[i][j + 1]) i++
    else j++
  }
  return { a: keepA, b: keepB }
}

/** Which word-tokens changed between two lines (per side, aligned to words()). */
export function changedWords(before: string, after: string): { a: boolean[]; b: boolean[] } {
  const keep = lcsKeep(words(before), words(after))
  return { a: keep.a.map((k) => !k), b: keep.b.map((k) => !k) }
}

export interface Hunk {
  /** first affected line index in `before` (deletion point when del is empty) */
  aStart: number
  del: string[]
  add: string[]
}

/** Contiguous change groups between two texts, line-mode LCS. */
export function lineHunks(before: string, after: string): Hunk[] {
  const a = before.split('\n')
  const b = after.split('\n')
  const keep = lcsKeep(a, b)
  const hunks: Hunk[] = []
  let i = 0
  let j = 0
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && keep.a[i] && keep.b[j]) { i++; j++; continue }
    const h: Hunk = { aStart: i, del: [], add: [] }
    while (i < a.length && !keep.a[i]) h.del.push(a[i++])
    while (j < b.length && !keep.b[j]) h.add.push(b[j++])
    if (h.del.length || h.add.length) hunks.push(h)
    else break // safety: no progress possible
  }
  return hunks
}

/** Rebuild `after` applying only the hunks whose index is in `keepIdx`. */
export function applyHunks(before: string, hunks: Hunk[], keepIdx: Set<number>): string {
  const a = before.split('\n')
  const out: string[] = []
  let cursor = 0
  hunks.forEach((h, idx) => {
    // unchanged run before this hunk
    for (; cursor < h.aStart; cursor++) out.push(a[cursor])
    if (keepIdx.has(idx)) {
      out.push(...h.add) // take the change
      cursor += h.del.length
    } else {
      out.push(...h.del) // keep the original lines
      cursor += h.del.length
    }
  })
  for (; cursor < a.length; cursor++) out.push(a[cursor])
  return out.join('\n')
}
