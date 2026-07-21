import { Fragment, useCallback, useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { bridge, isDesktop, type SavedWindowSummary } from '../../lib/bridge'
import { Icon } from '../Icon'

const triggerWrap: CSSProperties = {
  alignSelf: 'center',
  display: 'inline-flex',
  alignItems: 'center',
  flex: '0 0 auto',
  position: 'relative',
}

const statusLabel = (saved: SavedWindowSummary) => saved.current
  ? 'This window'
  : saved.open
    ? 'Open'
    : 'Parked'

const windowLabel = (saved: SavedWindowSummary) => saved.title || (saved.slot == null ? 'Primary window' : `Window ${saved.slot}`)

export function SavedWindows({ hostSelector = '.tabstrip' }: { hostSelector?: string }) {
  const [host, setHost] = useState<Element | null>(null)
  const [open, setOpen] = useState(false)
  const [saved, setSaved] = useState<SavedWindowSummary[]>([])
  const [loading, setLoading] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [position, setPosition] = useState({ top: 42, left: 10 })
  const trigger = useRef<HTMLButtonElement>(null)

  const refresh = useCallback(async () => {
    if (!bridge.windows?.listSaved) return
    setLoading(true)
    try {
      const result = await bridge.windows.listSaved()
      if (result.ok) setSaved(result.windows)
      else if (result.message) setNotice(result.message)
    } catch {
      setNotice('Saved windows could not be loaded.')
    } finally {
      setLoading(false)
    }
  }, [])

  useLayoutEffect(() => {
    if (isDesktop) setHost(document.querySelector(hostSelector))
  }, [hostSelector])
  useEffect(() => {
    if (!isDesktop) return
    void refresh()
    return bridge.windows?.onSavedChanged?.(() => { void refresh() })
  }, [refresh])
  useEffect(() => { if (open) void refresh() }, [open, refresh])

  if (!isDesktop || !host) return null
  const parked = saved.filter((entry) => !entry.open).length
  const toggle = () => {
    if (!open) {
      const rect = trigger.current?.getBoundingClientRect()
      if (rect) {
        const width = Math.min(360, window.innerWidth - 20)
        setPosition({
          top: Math.min(rect.bottom + 6, window.innerHeight - 220),
          left: Math.max(10, Math.min(rect.left, window.innerWidth - width - 10)),
        })
      }
    }
    setOpen((value) => !value)
  }

  const reopen = async (entry: SavedWindowSummary) => {
    setBusyId(entry.id)
    setNotice(null)
    try {
      const result = await bridge.windows!.reopenSaved(entry.id)
      if (!result.ok) setNotice(result.message || 'That window could not be reopened.')
      else if (!entry.current) setOpen(false)
    } catch {
      setNotice('That window could not be reopened.')
    } finally {
      setBusyId(null)
      void refresh()
    }
  }

  const remove = async (entry: SavedWindowSummary) => {
    setBusyId(entry.id)
    setNotice(null)
    try {
      const result = await bridge.windows!.deleteSaved(entry.id)
      if (!result.ok && !result.cancelled) setNotice(result.message || 'That saved window was not deleted.')
    } catch {
      // Deleting this exact live renderer intentionally tears down the caller,
      // so its invoke can disappear with it. Another window receives the
      // saved-changed event; a surviving caller gets a normal result here.
      setNotice('The saved-window transaction did not return a result.')
    } finally {
      setBusyId(null)
      void refresh()
    }
  }

  return (
    <Fragment>
      {createPortal(
        <div style={triggerWrap}>
          <button
            type="button"
            ref={trigger}
            className="tabstrip-new-btn"
            onClick={toggle}
            aria-label="Saved windows"
            aria-haspopup="dialog"
            aria-expanded={open}
            title="Saved windows"
          >
            <Icon name="AppWindow" size={14} />
          </button>
          {parked > 0 && (
            <span
              aria-hidden="true"
              style={{ position: 'absolute', top: 1, right: 0, minWidth: 12, height: 12, padding: '0 3px', borderRadius: 8, background: 'var(--accent)', color: 'var(--accent-contrast, white)', fontSize: 8, lineHeight: '12px', textAlign: 'center', pointerEvents: 'none' }}
            >
              {parked > 9 ? '9+' : parked}
            </span>
          )}
        </div>,
        host,
      )}
      {open && createPortal(
        <>
          <button
            type="button"
            className="tree-menu-overlay"
            aria-label="Close saved windows"
            onMouseDown={() => setOpen(false)}
            style={{ background: 'transparent', border: 'none', padding: 0 }}
          />
          <section
            className="tree-menu"
            role="dialog"
            aria-label="Saved windows"
            style={{ top: position.top, left: position.left, width: 360, maxWidth: 'calc(100vw - 20px)', maxHeight: 'min(520px, calc(100vh - 54px))', overflowY: 'auto', zIndex: 'calc(var(--z-palette) + 1)', padding: 8, gap: 6 }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 7px 7px' }}>
              <Icon name="AppWindow" size={14} />
              <strong style={{ fontSize: 'var(--fs-13)', color: 'var(--text-0)' }}>Saved windows</strong>
              <span style={{ marginLeft: 'auto', color: 'var(--text-3)', fontSize: 'var(--fs-11)' }}>{saved.length}</span>
            </div>
            {loading && saved.length === 0 ? (
              <div style={{ padding: 14, color: 'var(--text-3)', fontSize: 'var(--fs-12)' }}>Loading…</div>
            ) : saved.length === 0 ? (
              <div style={{ padding: 14, color: 'var(--text-3)', fontSize: 'var(--fs-12)' }}>No saved windows yet.</div>
            ) : saved.map((entry) => (
              <div
                key={entry.id}
                onDoubleClick={() => { void reopen(entry) }}
                title="Double-click to reopen"
                style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) auto auto', alignItems: 'center', gap: 6, padding: '8px 7px 8px 10px', border: '1px solid var(--border-faint)', borderRadius: 'var(--r-2)', background: entry.current ? 'color-mix(in srgb, var(--accent) 8%, transparent)' : 'var(--bg-2)', cursor: 'default' }}
              >
                <div style={{ minWidth: 0 }}>
                  <div className="truncate" style={{ color: 'var(--text-1)', fontSize: 'var(--fs-12)', fontWeight: 'var(--fw-medium)' }}>{windowLabel(entry)}</div>
                  <div style={{ display: 'flex', gap: 6, marginTop: 3, color: 'var(--text-3)', fontSize: 'var(--fs-10)' }}>
                    <span>{statusLabel(entry)}</span>
                    {entry.projectCount != null && <span>· {entry.projectCount} project{entry.projectCount === 1 ? '' : 's'}</span>}
                    <span>· {new Date(entry.updatedAt).toLocaleDateString()}</span>
                  </div>
                </div>
                <button
                  type="button"
                  className="btn btn-ghost btn-sm"
                  disabled={busyId === entry.id}
                  onClick={(event) => { event.stopPropagation(); void reopen(entry) }}
                  onDoubleClick={(event) => event.stopPropagation()}
                >
                  {entry.open ? 'Focus' : 'Open'}
                </button>
                <button
                  type="button"
                  className="btn-icon btn-sm"
                  disabled={busyId === entry.id}
                  onClick={(event) => { event.stopPropagation(); void remove(entry) }}
                  onDoubleClick={(event) => event.stopPropagation()}
                  aria-label={`Delete ${windowLabel(entry)}`}
                  title="Delete saved window…"
                  style={{ color: 'var(--danger)' }}
                >
                  <Icon name="Trash2" size={13} />
                </button>
              </div>
            ))}
            {notice && <div role="status" style={{ padding: '3px 7px', color: 'var(--warning, var(--text-2))', fontSize: 'var(--fs-11)', lineHeight: 1.4 }}>{notice}</div>}
            <div className="tree-menu-sep" />
            <button
              type="button"
              className="tree-menu-item"
              onClick={() => { void bridge.windows?.newWindow(); setOpen(false) }}
            >
              <Icon name="Plus" size={13} /> New window
            </button>
            <div style={{ padding: '2px 8px 4px', color: 'var(--text-3)', fontSize: 'var(--fs-10)' }}>Double-click a saved entry to reopen it.</div>
          </section>
        </>,
        document.body,
      )}
    </Fragment>
  )
}
