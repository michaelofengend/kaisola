import { useEffect, useMemo, useState } from 'react'
import { useKaisola } from '../../store/store'
import {
  CompanionProjectionRevisions,
  type CompanionProjection,
} from '../../lib/companionProjection'
import { Icon } from '../Icon'

type Session = CompanionProjection['sessions'][number]
type Attention = CompanionProjection['attention'][number]

const relTime = (at: number): string => {
  if (!at) return ''
  const s = Math.max(0, Math.round((Date.now() - at) / 1000))
  if (s < 60) return 'now'
  if (s < 3600) return `${Math.round(s / 60)}m`
  if (s < 86_400) return `${Math.round(s / 3600)}h`
  return `${Math.round(s / 86_400)}d`
}

const SEVERITY_RANK = { critical: 0, warning: 1, info: 2 } as const

/** The Board renders the same projection the phone consumes — one
 * normalization for every remote surface, so they can never disagree. */
function useBoardProjection(): CompanionProjection | null {
  const [projection, setProjection] = useState<CompanionProjection | null>(null)
  useEffect(() => {
    const revisions = new CompanionProjectionRevisions()
    let timer: number | null = null
    const recompute = () => {
      timer = null
      try {
        const next = revisions.next(useKaisola.getState(), Date.now())
        if (next) setProjection(next)
      } catch { /* keep the last good projection on malformed legacy state */ }
    }
    const schedule = () => {
      if (timer == null) timer = window.setTimeout(recompute, 120)
    }
    const unsubscribe = useKaisola.subscribe(schedule)
    recompute()
    return () => {
      if (timer != null) window.clearTimeout(timer)
      unsubscribe()
    }
  }, [])
  return projection
}

export function BoardView() {
  const projection = useBoardProjection()
  const switchProject = useKaisola((s) => s.switchProject)
  const setActiveThread = useKaisola((s) => s.setActiveThread)
  const setBoardOpen = useKaisola((s) => s.setBoardOpen)

  const board = useMemo(() => {
    const sessions = projection?.sessions ?? []
    const attention = projection?.attention ?? []
    const permissions = projection?.permissions ?? []
    const projectName = new Map((projection?.projects ?? []).map((p) => [p.id, p.name]))

    const permsBySession = new Map<string, number>()
    for (const perm of permissions) {
      if (!perm.sessionId) continue
      permsBySession.set(perm.sessionId, (permsBySession.get(perm.sessionId) ?? 0) + 1)
    }
    const needs = sessions
      .filter((s) => s.needsYou || s.status === 'waiting' || s.status === 'failed')
      .sort((a, b) => {
        const sev = (s: Session) => (s.status === 'failed' ? 0 : permsBySession.has(s.id) ? 0 : 1)
        return sev(a) - sev(b) || a.updatedAt - b.updatedAt // longest-waiting first
      })
    const needsIds = new Set(needs.map((s) => s.id))
    const running = sessions
      .filter((s) => s.status === 'running' && !needsIds.has(s.id))
      .sort((a, b) => (b.startedAt ?? b.updatedAt) - (a.startedAt ?? a.updatedAt))
    const done = sessions
      .filter((s) => s.status === 'done' && !needsIds.has(s.id))
      .sort((a, b) => b.updatedAt - a.updatedAt)
    const standalone = [...attention].sort((a, b) =>
      SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity] || a.createdAt - b.createdAt)
    const projectCount = new Set(sessions.map((s) => s.projectId)).size
    return { running, needs, done, standalone, permsBySession, projectName, projectCount }
  }, [projection])

  const openSession = (session: Session) => {
    setBoardOpen(false)
    switchProject(session.projectId)
    if (session.kind !== 'terminal') {
      try { setActiveThread(session.id) } catch { /* project view is still the right place */ }
    }
  }
  const openProject = (projectId: string) => {
    setBoardOpen(false)
    switchProject(projectId)
  }

  const needsTotal = board.needs.length + board.standalone.length
  const summary = `${needsTotal} need${needsTotal === 1 ? 's' : ''} you · ${board.running.length} running · ${board.done.length} done`
    + (board.projectCount > 1 ? ` across ${board.projectCount} projects` : '')

  const needsKind = (s: Session): string => {
    if (s.status === 'failed') return 'Failed'
    if (board.permsBySession.has(s.id)) return 'Permission'
    return 'Waiting'
  }

  return (
    <div className="board" role="main" aria-label="Board">
      <header className="board-head">
        <span className="board-summary">{summary}</span>
        <span className="board-live" data-live="true">
          <span className="board-live-dot" aria-hidden />
          Live
        </span>
      </header>
      <div className="board-lanes">
        <section className="board-lane" data-lane="running" aria-label={`Running, ${board.running.length}`}>
          <h2 className="board-lane-head">Running <span className="board-lane-count">{board.running.length}</span></h2>
          <div className="board-lane-scroll">
            {board.running.length === 0 && <p className="board-empty">Nothing running. Start an agent from any project.</p>}
            {board.running.map((s) => (
              <button type="button" key={s.id} className="board-card" data-state="running" onClick={() => openSession(s)}>
                <span className="board-card-top">
                  <span className="board-pulse" aria-hidden />
                  <span className="board-card-project">{board.projectName.get(s.projectId) ?? s.projectId}</span>
                  <span className="board-card-time">{relTime(s.startedAt ?? s.updatedAt)}</span>
                </span>
                <span className="board-card-title">{s.title}</span>
                {s.summary && <code className="board-card-activity">{s.summary}</code>}
                <span className="board-card-meta">{[s.provider, s.model, s.branch].filter(Boolean).join(' · ')}</span>
              </button>
            ))}
          </div>
        </section>
        <section className="board-lane" data-lane="needs" aria-label={`Needs you, ${needsTotal}`}>
          <h2 className="board-lane-head">Needs You <span className="board-lane-count">{needsTotal}</span></h2>
          <div className="board-lane-scroll">
            {needsTotal === 0 && <p className="board-empty">Nothing needs you.</p>}
            {board.needs.map((s) => {
              const extra = (board.permsBySession.get(s.id) ?? 0) - 1
              return (
                <button type="button" key={s.id} className="board-card" data-state={s.status === 'failed' ? 'failed' : 'needs'} onClick={() => openSession(s)}>
                  <span className="board-card-top">
                    <span className="board-card-kind">{needsKind(s)}</span>
                    <span className="board-card-project">{board.projectName.get(s.projectId) ?? s.projectId}</span>
                    <span className="board-card-age">{relTime(s.updatedAt)}</span>
                  </span>
                  <span className="board-card-title">{s.title}</span>
                  {s.summary && <span className="board-card-detail">{s.summary}</span>}
                  <span className="board-card-meta">
                    {[s.provider, extra > 0 ? `+${extra} more` : null].filter(Boolean).join(' · ')}
                  </span>
                </button>
              )
            })}
            {board.standalone.map((a: Attention) => (
              <button type="button" key={a.id} className="board-card" data-state={a.severity === 'critical' ? 'failed' : 'needs'} onClick={() => openProject(a.projectId)}>
                <span className="board-card-top">
                  <span className="board-card-kind">{a.kind === 'review' ? 'Review' : a.kind === 'blocked' ? 'Blocked' : 'Failed'}</span>
                  <span className="board-card-project">{board.projectName.get(a.projectId) ?? a.projectId}</span>
                  <span className="board-card-age">{relTime(a.createdAt)}</span>
                </span>
                <span className="board-card-title">{a.title}</span>
                {a.detail && <span className="board-card-detail">{a.detail}</span>}
              </button>
            ))}
          </div>
        </section>
        <section className="board-lane" data-lane="done" aria-label={`Done, ${board.done.length}`}>
          <h2 className="board-lane-head">Done <span className="board-lane-count">{board.done.length}</span></h2>
          <div className="board-lane-scroll">
            {board.done.length === 0 && <p className="board-empty">Finished sessions land here.</p>}
            {board.done.map((s) => (
              <button type="button" key={s.id} className="board-card board-card-done" data-state="done" onClick={() => openSession(s)}>
                <span className="board-card-top">
                  <Icon name="CircleCheck" size={12} className="board-done-check" />
                  <span className="board-card-project">{board.projectName.get(s.projectId) ?? s.projectId}</span>
                  <span className="board-card-time">{relTime(s.updatedAt)}</span>
                </span>
                <span className="board-card-title">{s.title}</span>
                {s.summary && <span className="board-card-detail">{s.summary}</span>}
              </button>
            ))}
          </div>
        </section>
      </div>
    </div>
  )
}
