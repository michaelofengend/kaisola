import { useEffect, type RefObject } from 'react'

/**
 * Dismiss a portalled preview without swallowing the click meant for the
 * surface underneath it. Capture phase matters: Settings and several shell
 * cards deliberately stop bubbling pointer events at their own boundaries.
 */
export function useClickAway(
  open: boolean,
  close: () => void,
  trigger: RefObject<HTMLElement | null>,
  panel: RefObject<HTMLElement | null>,
) {
  useEffect(() => {
    if (!open) return
    const onPointer = (event: PointerEvent) => {
      const target = event.target as Node | null
      if (target && (trigger.current?.contains(target) || panel.current?.contains(target))) return
      close()
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.stopPropagation()
      close()
    }
    document.addEventListener('pointerdown', onPointer, true)
    window.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('pointerdown', onPointer, true)
      window.removeEventListener('keydown', onKey, true)
    }
  }, [open, close, trigger, panel])
}
