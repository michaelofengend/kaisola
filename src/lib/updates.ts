import { useEffect, useState } from 'react'
import { bridge, type UpdateState } from './bridge'

/**
 * Live update status, shared by the tab-strip pill and Settings → General.
 * Pulls the main-process snapshot on mount (events may have fired before we
 * subscribed), then follows the event stream. Web builds stay at 'idle'.
 */
export function useUpdateState(): UpdateState {
  const [state, setState] = useState<UpdateState>({ type: 'idle' })
  useEffect(() => {
    if (!bridge.update) return
    let live = true
    bridge.update.state().then((s) => { if (live) setState(s) }).catch(() => {})
    const off = bridge.update.onEvent((s) => { if (live) setState(s) })
    return () => { live = false; off() }
  }, [])
  return state
}
