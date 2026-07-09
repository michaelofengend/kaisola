import type { ProposalChange } from '../domain/types'
import { useKaisola } from '../store/store'
import { words, changedWords } from '../lib/wordDiff'
import { Icon } from './Icon'

/**
 * The signature primitive — a research diff. The analogue of Cursor's code diff,
 * but for scientific objects: a changed claim, an added limitation, a removed
 * citation. before → after, with the agent's reason.
 */

/** One side of a text pair with its changed words marked (Settings → Interface). */
function WordMarked({ text, changed }: { text: string; changed: boolean[] }) {
  const toks = words(text)
  return (
    <>
      {toks.map((t, i) =>
        changed[i] && t.trim() !== '' ? <mark key={i} className="rdiff-word">{t}</mark> : t,
      )}
    </>
  )
}

/** Pair the i-th deleted line with the i-th added line inside one -/+ run. */
function pairPatchLines(lines: string[]): Map<number, { other: string; side: 'a' | 'b' }> {
  const pairs = new Map<number, { other: string; side: 'a' | 'b' }>()
  let i = 0
  while (i < lines.length) {
    if (lines[i].startsWith('-') && !lines[i].startsWith('---')) {
      const delStart = i
      while (i < lines.length && lines[i].startsWith('-') && !lines[i].startsWith('---')) i++
      const addStart = i
      while (i < lines.length && lines[i].startsWith('+') && !lines[i].startsWith('+++')) i++
      const dels = addStart - delStart
      const adds = i - addStart
      for (let k = 0; k < Math.min(dels, adds); k++) {
        pairs.set(delStart + k, { other: lines[addStart + k].slice(1), side: 'a' })
        pairs.set(addStart + k, { other: lines[delStart + k].slice(1), side: 'b' })
      }
    } else i++
  }
  return pairs
}

export function ResearchDiff({ change }: { change: ProposalChange }) {
  const wordDiffs = useKaisola((s) => s.wordDiffs)
  const verb =
    change.kind === 'create' ? 'add' : change.kind === 'delete' ? 'remove' : 'change'

  // a file-patch change (from a coding agent's worktree) renders as a code diff
  if (change.entityType === 'file') {
    const patch = (change.payload as { patch?: string } | undefined)?.patch ?? change.after ?? ''
    const lines = patch.split('\n')
    const pairs = wordDiffs ? pairPatchLines(lines) : new Map<number, { other: string; side: 'a' | 'b' }>()
    return (
      <div className="rdiff rdiff-file">
        <div className="rdiff-head">
          <span className={`rdiff-kind rdiff-${change.kind}`}>{verb}</span>
          <span className="rdiff-entity">file</span>
          <span className="rdiff-label grow truncate">{change.label}</span>
          {change.reason && <span className="rdiff-stat faint">{change.reason}</span>}
        </div>
        <pre className="rdiff-patch">
          {lines.map((line, i) => {
            const cls =
              line.startsWith('@@') ? 'pl-hunk'
                : line.startsWith('+') && !line.startsWith('+++') ? 'pl-add'
                  : line.startsWith('-') && !line.startsWith('---') ? 'pl-del'
                    : ''
            const pair = pairs.get(i)
            if (pair) {
              // word-mark this line against its counterpart across the -/+ run
              const self = line.slice(1)
              const ch = changedWords(pair.side === 'a' ? self : pair.other, pair.side === 'a' ? pair.other : self)
              return (
                <div key={i} className={cls}>
                  {line[0]}
                  <WordMarked text={self} changed={pair.side === 'a' ? ch.a : ch.b} />
                </div>
              )
            }
            return <div key={i} className={cls}>{line || ' '}</div>
          })}
        </pre>
      </div>
    )
  }

  const marked = wordDiffs && change.before != null && change.after != null
    ? changedWords(change.before, change.after)
    : null

  return (
    <div className="rdiff">
      <div className="rdiff-head">
        <span className={`rdiff-kind rdiff-${change.kind}`}>{verb}</span>
        <span className="rdiff-entity">{change.entityType.replace('-', ' ')}</span>
        <span className="rdiff-label grow truncate">{change.label}</span>
      </div>

      <div className="rdiff-body">
        {change.before != null && (
          <div className="rdiff-line rdiff-line-del">
            <span className="rdiff-gutter">−</span>
            <span className="rdiff-text serif">
              {marked ? <WordMarked text={change.before} changed={marked.a} /> : change.before}
            </span>
          </div>
        )}
        {change.after != null && (
          <div className="rdiff-line rdiff-line-add">
            <span className="rdiff-gutter">+</span>
            <span className="rdiff-text serif">
              {marked ? <WordMarked text={change.after} changed={marked.b} /> : change.after}
            </span>
          </div>
        )}
      </div>

      {change.reason && (
        <div className="rdiff-reason">
          <Icon name="CornerDownRight" size={12} />
          <span className="grow">{change.reason}</span>
        </div>
      )}
    </div>
  )
}
