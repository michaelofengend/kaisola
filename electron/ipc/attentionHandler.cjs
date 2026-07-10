const attentionByRenderer = new Map()
const trackedRenderers = new Set()
const lastNoticeAt = new Map()

function boundedCount(value) {
  const count = Number(value)
  return Number.isFinite(count) ? Math.min(999, Math.max(0, Math.floor(count))) : 0
}

function safeNotice(value) {
  if (!value || typeof value !== 'object') return null
  const title = typeof value.title === 'string' ? value.title.trim().slice(0, 100) : ''
  const body = typeof value.body === 'string' ? value.body.trim().slice(0, 300) : ''
  if (!title) return null
  return {
    title,
    body,
    projectId: typeof value.projectId === 'string' ? value.projectId.slice(0, 160) : undefined,
    sessionId: typeof value.sessionId === 'string' ? value.sessionId.slice(0, 160) : undefined,
  }
}

function registerAttentionHandlers(ipcMain, { app, BrowserWindow, Notification }) {
  const syncBadge = () => {
    if (process.platform !== 'darwin' || !app.dock?.setBadge) return
    const total = [...attentionByRenderer.values()].reduce((sum, count) => sum + count, 0)
    app.dock.setBadge(total > 0 ? String(Math.min(999, total)) : '')
  }
  const forget = (sender) => {
    attentionByRenderer.delete(sender.id)
    trackedRenderers.delete(sender.id)
    syncBadge()
  }

  ipcMain.on('attention:count', (event, value) => {
    if (event.sender.isDestroyed()) return
    attentionByRenderer.set(event.sender.id, boundedCount(value))
    if (!trackedRenderers.has(event.sender.id)) {
      trackedRenderers.add(event.sender.id)
      event.sender.once('destroyed', () => forget(event.sender))
    }
    syncBadge()
  })

  ipcMain.on('attention:notify', (event, raw) => {
    const payload = safeNotice(raw)
    if (!payload || event.sender.isDestroyed() || !Notification?.isSupported?.()) return
    const noticeKey = `${event.sender.id}\0${payload.projectId ?? ''}\0${payload.sessionId ?? ''}`
    const now = Date.now()
    if (now - (lastNoticeAt.get(noticeKey) ?? 0) < 12_000) return
    lastNoticeAt.set(noticeKey, now)
    if (lastNoticeAt.size > 512) {
      for (const [key, at] of lastNoticeAt) if (now - at > 60_000) lastNoticeAt.delete(key)
    }
    const owner = BrowserWindow.fromWebContents(event.sender)
    if (!owner || owner.isDestroyed()) return
    const notice = new Notification({ title: payload.title, body: payload.body, silent: true })
    notice.on('click', () => {
      if (owner.isDestroyed() || owner.webContents.isDestroyed()) return
      if (owner.isMinimized()) owner.restore()
      owner.show()
      owner.focus()
      owner.webContents.send('attention:open', {
        projectId: payload.projectId,
        sessionId: payload.sessionId,
      })
    })
    notice.show()
    if (!BrowserWindow.getFocusedWindow() && process.platform === 'darwin' && app.dock?.bounce) {
      app.dock.bounce('informational')
    }
  })
}

module.exports = { boundedCount, safeNotice, registerAttentionHandlers }
