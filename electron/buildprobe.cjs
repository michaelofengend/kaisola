// Repro for "Build says pick a .tex while one is open": the workspace scan
// runs once, so a .tex created AFTER it was invisible to the build target.
const { app, BrowserWindow, ipcMain } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fsx = require('node:fs')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers } = require('./ipc/terminalHandler.cjs')
const { registerAcpHandlers } = require('./ipc/acpHandler.cjs')
const { registerAuthHandlers } = require('./ipc/authHandler.cjs')
const { registerFsHandlers } = require('./ipc/fsHandler.cjs')
const { registerGrobidHandlers } = require('./ipc/grobidHandler.cjs')
const { registerSandboxHandlers } = require('./ipc/sandboxHandler.cjs')
const { registerDbHandlers } = require('./ipc/dbHandler.cjs')
const { registerCodexHandlers } = require('./ipc/codexHandler.cjs')
const { registerGitHandlers } = require('./ipc/gitHandler.cjs')
const { registerClaudeHooksHandlers } = require('./ipc/claudeHooksHandler.cjs')
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const { registerLatexHandlers } = require('./ipc/latexHandler.cjs')
const worktree = require('./ipc/worktreeHandler.cjs')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
app.setPath('userData', path.join(os.tmpdir(), 'kaisola-buildprobe'))
try { fsx.rmSync(app.getPath('userData'), { recursive: true, force: true }) } catch { /* fresh */ }

const ROOT = path.join(os.tmpdir(), 'kaisola-buildprobe-ws')
fsx.rmSync(ROOT, { recursive: true, force: true })
fsx.mkdirSync(ROOT, { recursive: true })
fsx.writeFileSync(path.join(ROOT, 'notes.md'), '# notes\n') // NO .tex at scan time

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
process.on('unhandledRejection', (err) => { console.log('PROBE_ERROR ' + ((err && err.message) || err)); app.exit(2) })
setTimeout(() => { console.log('PROBE_TIMEOUT'); app.exit(3) }, 90_000)

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerLatexHandlers(ipcMain)
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))

  const win = new BrowserWindow({
    show: false,
    width: 1440,
    height: 900,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      webviewTag: true,
      plugins: true,
    },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  win.webContents.on('console-message', (_e, level, message) => {
    if (level >= 2) console.log('RENDERER_LOG ' + String(message).slice(0, 240))
  })
  const js = (code) => win.webContents.executeJavaScript(code, true)
  await wait(800)
  await js(`window.__kaisola.getState().setWorkspace(${JSON.stringify(ROOT)})`)
  await wait(900) // let the LatexBar scan run and find NOTHING
  // the user's case: a PERSISTED main pointing at a file that no longer
  // exists (agent renamed it) — it must not shadow the open real file
  await js(`window.__kaisola.getState().setLatexMain(${JSON.stringify(ROOT)}, ${JSON.stringify(path.join(ROOT, 'ghost.tex'))})`)
  // the .tex arrives AFTER the scan (an agent writing the paper)
  fsx.writeFileSync(path.join(ROOT, 'paper.tex'), '\\documentclass{article}\n\\begin{document}\nHello.\n\\end{document}\n')
  await js(`window.__kaisola.getState().requestFile(${JSON.stringify(path.join(ROOT, 'paper.tex'))}, 'edit', { pinned: true })`)
  await js(`window.__kaisola.getState().setLatexMode(true)`)
  await wait(1200)
  const before = await js(`(() => {
    const btn = [...document.querySelectorAll('.fx-latexbar button')].find((b) => /Compile/.test(b.getAttribute('title') || ''))
    const anyBtn = [...document.querySelectorAll('.fx-latexbar button')].map((b) => ({ t: (b.getAttribute('title') || '').slice(0, 40), d: b.disabled }))
    return { compileBtn: btn ? { title: btn.getAttribute('title'), disabled: btn.disabled } : null, bar: !!document.querySelector('.fx-latexbar'), anyBtn }
  })()`)
  console.log('BEFORE_CLICK=' + JSON.stringify(before))
  const clicked = await js(`(() => {
    const btn = [...document.querySelectorAll('.fx-latexbar button')].find((b) => /Compile/.test(b.getAttribute('title') || ''))
    if (!btn || btn.disabled) return false
    btn.click()
    return true
  })()`)
  await wait(1000)
  const after = await js(`(async () => {
    const waitFor = (fn, ms) => new Promise((res) => { const t0 = Date.now(); const iv = setInterval(() => { const v = fn(); if (v || Date.now() - t0 > ms) { clearInterval(iv); res(v) } }, 120) })
    const spinnerSeen = !!document.querySelector('.fx-latexbar .spin') || await waitFor(() => document.querySelector('.fx-latexbar .spin'), 2000)
    await waitFor(() => !document.querySelector('.fx-latexbar .spin'), 60000)
    const outcome = await waitFor(() => document.querySelector('.fx-latex-ok') || document.querySelector('.fx-latex-issues'), 6000)
    const g = window.__kaisola.getState()
    return {
      spinnerSeen: !!spinnerSeen,
      okChip: !!document.querySelector('.fx-latex-ok'),
      issues: !!document.querySelector('.fx-latex-issues'),
      outcomeSeen: !!outcome,
      bars: document.querySelectorAll('.fx-latexbar').length,
      barText: (document.querySelector('.fx-latexbar')?.textContent || '').slice(0, 120),
      toasts: g.toasts.map((t) => t.text).slice(-3),
      latexMain: g.latexMain[${JSON.stringify(ROOT)}] ?? null,
      pdfOnDisk: await window.kaisola.fs.read(${JSON.stringify(path.join(ROOT, 'paper.pdf'))}).then((r) => !!r.ok, () => false),
    }
  })()`)
  console.log('AFTER_BUILD=' + JSON.stringify({ clicked, ...after }))
  const pageDirect = await js(`window.kaisola.latex.build(${JSON.stringify(path.join(ROOT, 'paper.tex'))}).then((r) => ({ ok: r?.ok, msg: String(r?.message || '').slice(0, 80), pdf: !!r?.pdf }), (e) => ({ threw: String(e).slice(0, 120) }))`)
  console.log('PAGE_DIRECT=' + JSON.stringify(pageDirect))
  app.exit(0)
})
