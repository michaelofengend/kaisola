import { useKaisola } from '../../store/store'
import { Icon } from '../Icon'
import { LimitsButton } from './LimitsButton'

/**
 * The global utility cluster stays deliberately small: find, usage, and
 * settings. Top navigation keeps only frequent actions here; Usage and
 * Settings remain available from the adjacent account menu. Left navigation
 * has enough room for the full utility set at the foot of the project tree.
 */
export function ShellTools({
  includeSettings = true,
  includeUsage = true,
}: {
  includeSettings?: boolean
  includeUsage?: boolean
}) {
  const openPalette = useKaisola((s) => s.openPalette)
  const openSettings = useKaisola((s) => s.setSettingsOpen)
  return (
    <>
      <button type="button" className="btn-icon" onClick={() => openPalette()} title="Command palette  ⌘K" aria-label="Open command palette">
        <Icon name="Search" size={15} />
      </button>
      {includeUsage && <LimitsButton />}
      {includeSettings && (
        <button type="button" className="btn-icon shell-settings-trigger" onClick={() => openSettings(true)} title="Settings  ⌘," aria-label="Open settings">
          <Icon name="Settings" size={15} />
        </button>
      )}
    </>
  )
}
