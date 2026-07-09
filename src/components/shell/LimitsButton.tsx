import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { bridge, isDesktop, type ClaudeUsage, type CodexUsage } from '../../lib/bridge'
import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'

/** Top-bar gauge: the current Claude + Codex subscription limits at a click.
 * Codex reports REAL window percentages (the CLI's app-server); Claude has no
 * sanctioned non-interactive readout, so we sum the local transcripts per
 * account (5h / 7d) and say so. */

const fmt = (n: number): string =>
  n >= 1e9 ? `${(n / 1e9).toFixed(1)}B`
    : n >= 1e6 ? `${(n / 1e6).toFixed(1)}M`
      : n >= 1e3 ? `${(n / 1e3).toFixed(0)}k`
        : String(n)

const resetIn = (epochSec?: number): string => {
  if (!epochSec) return ''
  const ms = epochSec * 1000 - Date.now()
  if (ms <= 0) return 'resets soon'
  const h = Math.floor(ms / 3_600_000)
  const m = Math.round((ms % 3_600_000) / 60_000)
  return h >= 48 ? `resets in ${Math.round(h / 24)}d` : h > 0 ? `resets in ${h}h ${m}m` : `resets in ${m}m`
}

function WindowBar({ label, usedPercent, resetsAt }: { label: string; usedPercent?: number; resetsAt?: number }) {
  const pct = Math.max(0, Math.min(100, usedPercent ?? 0))
  const tone = pct >= 90 ? 'var(--danger)' : pct >= 70 ? 'var(--warn)' : 'var(--accent)'
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
        <span>{label}</span>
        <span className="faint">{usedPercent != null ? `${Math.round(pct)}% · ${resetIn(resetsAt)}` : '—'}</span>
      </div>
      <div style={{ height: 4, borderRadius: 'var(--r-full)', background: 'var(--bg-inset)', overflow: 'hidden' }}>
        <div style={{ width: `${pct}%`, height: '100%', borderRadius: 'var(--r-full)', background: tone }} />
      </div>
    </div>
  )
}

function claudeLine(u?: ClaudeUsage): string {
  if (!u?.ok || !u.exists) return 'no local activity found'
  const sum = (s?: { input: number; output: number; cacheWrite: number }) =>
    s ? s.input + s.output + s.cacheWrite : 0
  return `5h ${fmt(sum(u.fiveHour))} · 7d ${fmt(sum(u.week))} tokens`
}

interface ClaudeRow { label: string; email?: string; usage?: ClaudeUsage }

export function LimitsButton() {
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState<{ right: number; top: number }>({ right: 12, top: 44 })
  const [loading, setLoading] = useState(false)
  const [codex, setCodex] = useState<CodexUsage | null>(null)
  const [claude, setClaude] = useState<ClaudeRow[]>([])
  const btnRef = useRef<HTMLButtonElement | null>(null)
  const seqRef = useRef(0)

  const load = async () => {
    if (!bridge.usage) return
    const seq = ++seqRef.current
    setLoading(true)
    const accounts = useKaisola.getState().claudeAccounts
    const [codexRes, defaultInfo, defaultUsage, ...accountUsages] = await Promise.all([
      bridge.usage.codex().catch(() => ({ ok: false, message: 'unavailable' } as CodexUsage)),
      bridge.claude.accountInfo?.().catch(() => undefined) ?? Promise.resolve(undefined),
      bridge.usage.claude().catch(() => undefined),
      ...accounts.map((a) => bridge.usage!.claude(a.configDir).catch(() => undefined)),
    ])
    if (seq !== seqRef.current) return // a newer refresh superseded this one
    setCodex(codexRes)
    setClaude([
      { label: 'Default', email: defaultInfo?.email, usage: defaultUsage },
      ...accounts.map((a, i) => ({ label: a.label, email: a.email, usage: accountUsages[i] })),
    ])
    setLoading(false)
  }

  const toggle = () => {
    if (!open) {
      const r = btnRef.current?.getBoundingClientRect()
      if (r) setPos({ right: Math.max(8, window.innerWidth - r.right), top: r.bottom + 6 })
      void load()
    }
    setOpen(!open)
  }

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open])

  if (!isDesktop || !bridge.usage) return null
  return (
    <>
      <button ref={btnRef} className="btn-icon" data-active={open} onClick={toggle} title="Subscription limits — Claude & Codex">
        <Icon name="Gauge" size={15} />
      </button>
      {open && createPortal(
        <div className="tree-menu-overlay" onMouseDown={() => setOpen(false)}>
          <div
            className="limits-panel"
            style={{
              position: 'fixed', right: pos.right, top: pos.top, width: 300, zIndex: 'var(--z-menu, 900)' as never,
              background: 'var(--bg-3)', border: '1px solid var(--border)', borderRadius: 'var(--r-3, 10px)',
              boxShadow: 'var(--shadow-3, 0 12px 40px rgba(0,0,0,.4))', padding: '10px 12px',
              display: 'flex', flexDirection: 'column', gap: 10, fontSize: 'var(--fs-12)',
            }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <Icon name="Gauge" size={13} />
              <span style={{ fontWeight: 600 }}>Limits</span>
              <span className="grow" />
              <button className="btn-icon btn-sm" onClick={() => void load()} title="Refresh">
                <Icon name="RefreshCw" size={12} />
              </button>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontWeight: 500 }}>Codex</span>
                <span className="faint truncate">{codex?.ok ? [codex.email, codex.plan].filter(Boolean).join(' · ') : ''}</span>
              </div>
              {codex?.ok ? (
                <>
                  <WindowBar label="5-hour window" usedPercent={codex.primary?.usedPercent} resetsAt={codex.primary?.resetsAt} />
                  <WindowBar label="Weekly" usedPercent={codex.secondary?.usedPercent} resetsAt={codex.secondary?.resetsAt} />
                </>
              ) : (
                <span className="faint">{loading ? 'Reading…' : codex?.message ?? 'Not available'}</span>
              )}
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontWeight: 500 }}>Claude</span>
                <span className="faint">local estimate</span>
              </div>
              {claude.length === 0 && <span className="faint">{loading ? 'Reading…' : 'No accounts'}</span>}
              {claude.map((row) => (
                <div key={row.label} style={{ display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
                  <span style={{ fontWeight: 500, whiteSpace: 'nowrap' }}>{row.label}</span>
                  <span className="faint truncate" title={row.email}>{claudeLine(row.usage)}</span>
                </div>
              ))}
              <span className="faint" style={{ fontSize: 'var(--fs-10, 10px)' }}>
                Anthropic exposes no exact meter — token sums from this Mac's transcripts. Run /usage in a Claude terminal for the official view.
              </span>
            </div>
          </div>
        </div>,
        document.body,
      )}
    </>
  )
}
