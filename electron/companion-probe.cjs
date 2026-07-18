// Real Electron + PTY loopback probe for the listener-free Companion Gateway.
// It intentionally grants the probe device only `observe`; agent and terminal
// control remain unavailable until their later guarded-control phases.
'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { app, BrowserWindow, ipcMain } = require('electron')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-probe-'))
app.setPath('userData', userData)

const { acpSessionService } = require('./ipc/acpHandler.cjs')
const { sessionBroker } = require('./ipc/sessionBrokerClient.cjs')
const { registerTerminalHandlers, subscribeTerminalObserver } = require('./ipc/terminalHandler.cjs')
const { AttentionService } = require('./ipc/attentionService.cjs')
const { CompanionDesktopState } = require('./companion/desktopState.cjs')
const { CompanionGateway } = require('./companion/gateway.cjs')
const { LoopbackCompanionTransport } = require('./companion/loopbackTransport.cjs')
const { CompanionProjectionStore } = require('./companion/projectionStore.cjs')
const { CompanionStateHub } = require('./companion/stateHub.cjs')

const DESKTOP_ID = 'desktop-companion-probe'
const DEVICE_ID = 'device-loopback-probe'
const EPOCH = 'desktop-epoch-companion-probe'
const PROJECT_ID = 'project-companion-probe'
const TERMINAL_ID = 'terminal-companion-probe'
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function waitFor(check, label, timeoutMs = 8_000) {
  const deadline = Date.now() + timeoutMs
  let last
  while (Date.now() < deadline) {
    last = await check()
    if (last) return last
    await wait(25)
  }
  throw new Error(`companion probe timed out waiting for ${label}`)
}

async function collectFrames(transport, predicate, label, timeoutMs = 8_000) {
  const frames = []
  return waitFor(() => {
    frames.push(...transport.receiveForDevice())
    return predicate(frames) ? frames : null
  }, label, timeoutMs)
}

function terminalText(frames) {
  return frames
    .filter((frame) => frame.kind === 'event' && (frame.body.type === 'terminal.snapshot' || frame.body.type === 'terminal.output'))
    .map((frame) => frame.body.output ?? frame.body.data ?? '')
    .join('')
}

function terminalCursor(frames) {
  const terminalFrames = frames.filter((frame) => frame.kind === 'event'
    && (frame.body.type === 'terminal.snapshot' || frame.body.type === 'terminal.output')
    && typeof frame.body.streamEpoch === 'string'
    && Number.isSafeInteger(frame.body.endOffset))
  const latest = terminalFrames.sort((a, b) => a.body.endOffset - b.body.endOffset).at(-1)
  return latest ? { streamEpoch: latest.body.streamEpoch, afterOffset: latest.body.endOffset } : null
}

function hello(connectionId, lastAck) {
  return {
    v: 1,
    kind: 'hello',
    desktopId: DESKTOP_ID,
    deviceId: DEVICE_ID,
    connectionId,
    epoch: EPOCH,
    seq: 0,
    id: `hello-${connectionId}`,
    sentAt: Date.now(),
    body: {
      type: 'hello',
      role: 'device',
      protocolMinor: 0,
      capabilities: ['observe'],
      ...(lastAck == null ? {} : { lastAck }),
    },
  }
}

function command(connectionId, commandId, type, capability, payload = {}, targetId = TERMINAL_ID) {
  return {
    v: 1,
    kind: 'command',
    desktopId: DESKTOP_ID,
    deviceId: DEVICE_ID,
    connectionId,
    epoch: EPOCH,
    seq: 1,
    id: commandId,
    sentAt: Date.now(),
    body: {
      type,
      commandId,
      projectId: PROJECT_ID,
      targetId,
      capability,
      payload,
    },
  }
}

function acknowledgement(connectionId, seq) {
  return {
    v: 1,
    kind: 'ack',
    desktopId: DESKTOP_ID,
    deviceId: DEVICE_ID,
    connectionId,
    epoch: EPOCH,
    seq,
    id: `ack-${seq}`,
    sentAt: Date.now(),
    body: { type: 'ack', ackSeq: seq },
  }
}

function ownership(row) {
  return row && {
    owner: row.owner,
    lastOwner: row.lastOwner,
    visible: row.visible,
  }
}

async function main() {
  let win = null
  let gateway = null
  let broker = null
  let terminalCreated = false
  try {
    registerTerminalHandlers(ipcMain)
    broker = sessionBroker()

    win = new BrowserWindow({
      show: false,
      width: 640,
      height: 480,
      webPreferences: { contextIsolation: true, nodeIntegration: false },
    })
    await win.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent('<title>Kaisola Companion Probe</title><main>Desktop owner</main>')}`)
    assert.equal(BrowserWindow.getAllWindows().includes(win), true)

    const shell = process.platform === 'win32' ? process.env.ComSpec : '/bin/sh'
    const args = process.platform === 'win32'
      ? ['/d', '/s', '/c', 'echo probe-ready & for /l %i in (1,0,2) do @set /p line= & @echo probe:%line%']
      : ['-c', 'printf "probe-ready\\n"; while IFS= read -r line; do printf "probe:%s\\n" "$line"; done']
    const created = await broker.terminal('create', win.webContents, {
      id: TERMINAL_ID,
      command: shell,
      args,
      cwd: process.cwd(),
      cols: 80,
      rows: 24,
      projectId: PROJECT_ID,
      outputByteLimit: 512 * 1024,
    }, { timeoutMs: 20_000 })
    assert.equal(created?.ok, true, created?.message)
    assert.ok(Number.isInteger(created.pid) && created.pid > 1)
    terminalCreated = true

    const ownerSnapshot = () => broker.terminal('snapshot', win.webContents, { id: TERMINAL_ID, projectId: PROJECT_ID })
    await waitFor(async () => String((await ownerSnapshot()).output).includes('probe-ready'), 'initial PTY output')
    const diagnostics = async () => (await broker.terminal('diagnostics', win.webContents, { projectId: PROJECT_ID }))
      .find((row) => row.id === TERMINAL_ID)
    const before = ownership(await diagnostics())
    assert.ok(before?.owner && before.owner === before.lastOwner && before.visible === true)

    const storage = new Map()
    const attentionStorage = new Map()
    const attentionService = new AttentionService({
      get: (key) => attentionStorage.get(key) ?? null,
      set: (key, value) => attentionStorage.set(key, value),
    })
    const projectionStore = new CompanionProjectionStore({
      epoch: EPOCH,
      get: (key) => storage.get(key) ?? null,
      set: (key, value) => storage.set(key, value),
      del: (key) => storage.delete(key),
      keys: () => [...storage.keys()],
    })
    const desktopState = new CompanionDesktopState({ epoch: EPOCH, projectionStore, attentionService })
    gateway = new CompanionGateway({
      desktopId: DESKTOP_ID,
      epoch: EPOCH,
      stateHub: new CompanionStateHub({ desktopState }),
      terminalObserver: subscribeTerminalObserver,
      acpSessionService,
      attentionService,
      ledgerAdapter: { listTasks: () => [] },
      enabledCapabilities: ['observe'],
    })
    gateway.projectionPublished('probe-window', projectionStore.publish({
      windowId: 'probe-window',
      publisherGeneration: 1,
      projection: {
        projectionKind: 'kaisola.companion.projection',
        revision: 1,
        generatedAt: Date.now(),
        freshness: 'live',
        projects: [{
          id: PROJECT_ID,
          name: 'Companion Probe',
          repo: 'Kaisola',
          branch: 'main',
          connection: 'live',
          lastContactAt: Date.now(),
        }],
        sessions: [{
          id: TERMINAL_ID,
          projectId: PROJECT_ID,
          kind: 'terminal',
          title: 'Real PTY',
          status: 'running',
          needsYou: false,
          unread: false,
          updatedAt: Date.now(),
        }],
        attention: [],
        permissions: [],
      },
    }))

    const firstTransport = new LoopbackCompanionTransport()
    const firstSession = gateway.attach(firstTransport, { deviceId: DEVICE_ID, capabilities: ['observe'] })
    const firstConnection = 'connection-probe-first'
    await firstTransport.sendFromDevice(hello(firstConnection))
    const initialFrames = firstTransport.receiveForDevice()
    const initialSnapshot = initialFrames.find((frame) => frame.kind === 'snapshot')
    assert.ok(initialSnapshot)
    assert.equal(initialSnapshot.body.projection.freshness, 'live')
    assert.equal(initialSnapshot.body.projection.projects.some(({ id }) => id === PROJECT_ID), true)
    assert.equal(initialSnapshot.body.projection.sessions.some(({ id }) => id === TERMINAL_ID), true)
    assert.deepEqual(initialFrames.find((frame) => frame.kind === 'hello').body.capabilities, ['observe'])

    const subscribed = await firstTransport.sendFromDevice(command(
      firstConnection,
      'stream-subscribe-first',
      'stream.subscribe',
      'observe',
    ))
    assert.equal(subscribed.status, 'applied')
    const firstStreamFrames = await collectFrames(
      firstTransport,
      (frames) => terminalText(frames).includes('probe-ready'),
      'initial companion terminal snapshot',
    )

    await broker.terminal('write', win.webContents, { id: TERMINAL_ID, projectId: PROJECT_ID, data: 'first-live\r' })
    const liveFrames = await collectFrames(
      firstTransport,
      (frames) => terminalText(frames).includes('probe:first-live'),
      'live companion terminal output',
    )
    await wait(100)
    liveFrames.push(...firstTransport.receiveForDevice())
    const firstCursor = terminalCursor([...firstStreamFrames, ...liveFrames])
    assert.ok(firstCursor)
    const duringFirstConnection = ownership(await diagnostics())
    const lastEventSeq = Math.max(...[...firstStreamFrames, ...liveFrames]
      .filter((frame) => frame.kind === 'event')
      .map((frame) => frame.seq))
    await firstTransport.sendFromDevice(acknowledgement(firstConnection, lastEventSeq))

    firstSession.close('probe_disconnect')
    await gateway.settle()
    assert.equal((await diagnostics()).observerCount, 0)

    await broker.terminal('write', win.webContents, { id: TERMINAL_ID, projectId: PROJECT_ID, data: 'second-offline\r' })
    await waitFor(async () => String((await ownerSnapshot()).output).includes('probe:second-offline'), 'disconnected PTY output')
    const whileDisconnected = ownership(await diagnostics())

    const reconnectTransport = new LoopbackCompanionTransport()
    gateway.attach(reconnectTransport, { deviceId: DEVICE_ID, capabilities: ['observe'] })
    const reconnectId = 'connection-probe-reconnect'
    await reconnectTransport.sendFromDevice(hello(reconnectId, lastEventSeq))
    const reconnectHelloFrames = reconnectTransport.receiveForDevice()
    assert.deepEqual(reconnectHelloFrames.map(({ kind }) => kind), ['hello'])

    const resumed = await reconnectTransport.sendFromDevice(command(
      reconnectId,
      'stream-subscribe-resume',
      'stream.subscribe',
      'observe',
      firstCursor,
    ))
    assert.equal(resumed.status, 'applied')
    const resumedFrames = await collectFrames(
      reconnectTransport,
      (frames) => terminalText(frames).includes('probe:second-offline'),
      'cursor-resumed terminal suffix',
    )
    // The log replay legitimately redelivers un-acked events first (original
    // snapshot + outputs, in seq order); the cursor-resume snapshot follows.
    const streamFrames = resumedFrames.filter((frame) => frame.kind === 'event'
      && (frame.body.type === 'terminal.snapshot' || frame.body.type === 'terminal.output'))
    for (let i = 1; i < streamFrames.length; i++) {
      assert.ok(streamFrames[i].seq > streamFrames[i - 1].seq, 'replayed frames arrive in seq order')
    }
    const resumedSnapshot = streamFrames.filter((frame) => frame.body.type === 'terminal.snapshot').at(-1)
    assert.equal(resumedSnapshot.body.streamEpoch, firstCursor.streamEpoch)
    assert.equal(resumedSnapshot.body.startOffset, firstCursor.afterOffset)
    const duringReconnect = ownership(await diagnostics())

    const agentControl = await reconnectTransport.sendFromDevice(command(
      reconnectId,
      'agent-cancel-disabled',
      'agent.cancel',
      'agent-control',
      {},
      'agent-companion-probe',
    ))
    const terminalControl = await reconnectTransport.sendFromDevice(command(
      reconnectId,
      'terminal-write-disabled',
      'terminal.write',
      'terminal-control',
      { data: 'must-not-run\r' },
    ))
    assert.equal(agentControl.status, 'rejected')
    assert.equal(terminalControl.status, 'rejected')
    assert.match(agentControl.message, /not granted/)
    assert.match(terminalControl.message, /not granted/)

    const after = ownership(await diagnostics())
    const finalOwnerSnapshot = await ownerSnapshot()
    const ownershipSamples = [before, duringFirstConnection, whileDisconnected, duringReconnect, after]
    const assertions = {
      realElectronWindow: !!win && !win.isDestroyed() && BrowserWindow.getAllWindows().includes(win),
      realPty: Number.isInteger(created.pid) && created.pid > 1,
      coherentSnapshot: initialSnapshot.body.projection.projects.length === 1
        && initialSnapshot.body.projection.sessions.some(({ id }) => id === TERMINAL_ID),
      liveTerminalOutput: terminalText(liveFrames).includes('probe:first-live'),
      disconnectedOutputPersisted: String(finalOwnerSnapshot.output).includes('probe:second-offline'),
      eventCursorReconnect: reconnectHelloFrames.length === 1 && reconnectHelloFrames[0].kind === 'hello',
      terminalCursorReconnect: terminalText(resumedFrames).includes('probe:second-offline')
        && resumedSnapshot.body.startOffset === firstCursor.afterOffset,
      observerCleanedOnDisconnect: firstSession.stats().terminalSubscriptions === 0,
      desktopOwnerStable: ownershipSamples.every((sample) => sample.owner === before.owner),
      desktopLastOwnerStable: ownershipSamples.every((sample) => sample.lastOwner === before.lastOwner),
      desktopVisibilityStable: ownershipSamples.every((sample) => sample.visible === true),
      observeOnlyDevice: gateway.stats().commandRouter.enabledCapabilities.join(',') === 'observe',
      agentControlDisabled: agentControl.status === 'rejected',
      terminalControlDisabled: terminalControl.status === 'rejected',
    }
    const failed = Object.entries(assertions).filter(([, ok]) => !ok).map(([name]) => name)
    console.log(JSON.stringify({
      windowId: win.id,
      terminalPid: created.pid,
      brokerPid: broker.hello?.pid,
      firstCursor,
      ownership: { before, duringFirstConnection, whileDisconnected, duringReconnect, after },
      gateway: gateway.stats(),
      assertions,
    }, null, 2))
    if (failed.length) throw new Error(`companion gateway probe failed: ${failed.join(', ')}`)
    console.log('COMPANION_PROBE_OWNERSHIP=PASS owner=true lastOwner=true visibility=true')
    console.log('COMPANION_PROBE_RESULT=PASS')
  } finally {
    try { await gateway?.dispose() } catch {}
    if (broker && terminalCreated && win && !win.isDestroyed()) {
      try { await broker.terminal('release', win.webContents, { id: TERMINAL_ID, projectId: PROJECT_ID }, { timeoutMs: 3_000 }) } catch {}
    }
    try { await broker?.shutdown() } catch {}
    try { if (win && !win.isDestroyed()) win.destroy() } catch {}
    await wait(100)
    try { fs.rmSync(userData, { recursive: true, force: true }) } catch {}
  }
}

// app.exit() before piped stdio flushes silently discards every probe line —
// drain both streams first so PASS/FAIL output survives `npm run … | tail`.
const exitFlushed = (code) => {
  process.stderr.write('', () => {
    process.stdout.write('', () => app.exit(code))
  })
}
app.whenReady().then(main).then(
  () => exitFlushed(0),
  (error) => {
    console.error(error?.stack || error)
    exitFlushed(1)
  },
)
