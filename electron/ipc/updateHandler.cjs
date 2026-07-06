// In-app software updates — electron-updater against the public GitHub
// releases feed (build.publish in package.json). CI uploads latest-mac.yml
// next to the dmg/zip on every v* tag; the app checks that file, downloads
// the zip in the background, and installs on restart.
//
// macOS requirement: the downloaded build's code signature must validate, so
// updates only work between Developer-ID-signed releases (the CI secrets
// path). Ad-hoc-signed local builds can check but will fail to install.
const { app, BrowserWindow } = require('electron')

const CHECK_EVERY_MS = 4 * 60 * 60 * 1000 // startup + every 4h
const FIRST_CHECK_DELAY_MS = 15 * 1000 // let the shell boot first

/** The single source of truth the renderer mirrors (late subscribers pull it). */
let state = { type: 'idle', version: null, percent: 0, message: null, appVersion: app.getVersion() }

function broadcast() {
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.webContents.isDestroyed()) w.webContents.send('update:event', state)
  }
}
function setState(patch) {
  state = { ...state, ...patch }
  broadcast()
}

function registerUpdateHandlers(ipcMain) {
  ipcMain.handle('update:state', () => state)

  // dev / smoke runs aren't packaged — expose inert handlers so the renderer
  // UI can render its "updates apply to installed builds" state without special-casing
  if (!app.isPackaged) {
    ipcMain.handle('update:check', () => ({ ok: false, message: 'Updates apply to the installed app, not dev builds.' }))
    ipcMain.handle('update:install', () => ({ ok: false }))
    return
  }

  const { autoUpdater } = require('electron-updater')
  autoUpdater.autoDownload = true
  // even if the user never clicks "Restart to update", the next quit applies it
  autoUpdater.autoInstallOnAppQuit = true

  autoUpdater.on('checking-for-update', () => setState({ type: 'checking', message: null }))
  autoUpdater.on('update-available', (info) => setState({ type: 'downloading', version: info.version, percent: 0 }))
  autoUpdater.on('update-not-available', () => setState({ type: 'idle', version: null, percent: 0 }))
  autoUpdater.on('download-progress', (p) => setState({ type: 'downloading', percent: Math.round(p.percent) }))
  autoUpdater.on('update-downloaded', (info) => setState({ type: 'ready', version: info.version, percent: 100 }))
  autoUpdater.on('error', (err) => setState({ type: 'error', message: err?.message ?? String(err) }))

  const check = async () => {
    try {
      await autoUpdater.checkForUpdates()
      return { ok: true }
    } catch (err) {
      // offline is the common case — record it quietly, never a dialog
      setState({ type: 'error', message: err?.message ?? String(err) })
      return { ok: false, message: err?.message ?? String(err) }
    }
  }

  ipcMain.handle('update:check', () => check())
  ipcMain.handle('update:install', () => {
    // before-quit (pty teardown etc.) still runs — quitAndInstall goes
    // through the normal quit path, then relaunches into the new build
    setImmediate(() => autoUpdater.quitAndInstall())
    return { ok: true }
  })

  setTimeout(() => void check(), FIRST_CHECK_DELAY_MS)
  setInterval(() => void check(), CHECK_EVERY_MS)
}

module.exports = { registerUpdateHandlers }
