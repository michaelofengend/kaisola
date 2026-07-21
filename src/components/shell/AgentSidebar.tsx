import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'

/**
 * The global utility cluster stays deliberately small: find, usage, and
 * settings. Top navigation places it at the upper right; Left navigation
 * keeps the identical controls at the bottom of the project tree.
 */
export function ShellTools({ includeSettings = true }: { includeSettings?: boolean }) {
  const openPalette = useKaisola((s) => s.openPalette)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  return (
    <>
      <button type="button" className="btn-icon" onClick={() => openPalette()} title="Command palette  ⌘K" aria-label="Open command palette">
        <Icon name="Search" size={15} />
      </button>
      <LimitsButton />
      {includeSettings && (
        <button type="button" className="btn-icon shell-settings-trigger" onClick={() => openSettings(true)} title="Settings  ⌘," aria-label="Open settings">
          <Icon name="Settings" size={15} />
        </button>
      )}
    </>
  )
}
