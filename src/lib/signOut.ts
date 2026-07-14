import { bridge, type AppAuthStatus } from './bridge'
import { useKaisola } from '../store/store'

const CONFIRM_SIGN_OUT = 'Sign out of Kaisola?\n\nYour local projects and files will stay on this Mac. You’ll return to the welcome screen.'

/** Sign out is deliberately one shared flow: both account entry points confirm,
 * clear the native session, and reopen onboarding only after native success. */
export async function signOutToOnboarding(): Promise<AppAuthStatus | null> {
  if (!window.confirm(CONFIRM_SIGN_OUT)) return null
  try {
    const status = await bridge.appAuth.signOut()
    if (status.ok === false) {
      useKaisola.getState().pushToast('error', status.message ?? 'Kaisola could not sign out.')
      return status
    }
    useKaisola.getState().restartOnboarding()
    return status
  } catch (error) {
    useKaisola.getState().pushToast('error', String((error as Error)?.message ?? 'Kaisola could not sign out.'))
    return null
  }
}
