'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const net = require('node:net')
const path = require('node:path')
const { spawn } = require('node:child_process')
const {
  PROTOCOL,
  SECURITY_EPOCH,
  BROKER_IMPLEMENTATION_VERSION,
  BROKER_PACKAGE_SCHEMA,
} = require('./ipc/brokerWire.cjs')

const BROKER_SCRIPT = path.join(__dirname, 'session-broker.cjs')
const TERMINAL_MANAGER_SOURCE = path.join(__dirname, 'ipc', 'terminalManager.cjs')
const REQUEST_TIMEOUT_MS = 5_000
const WAIT_TIMEOUT_MS = 8_000
const NO_EVENT_WINDOW_MS = 300

function readAgentQuietMs() {
  const source = fs.readFileSync(TERMINAL_MANAGER_SOURCE, 'utf8')
  const match = source.match(/\bconst AGENT_QUIET_MS\s*=\s*([0-9][0-9_]*)\b/)
  assert.ok(match, 'terminalManager.cjs must declare a numeric AGENT_QUIET_MS constant')
  const milliseconds = Number(match[1].replaceAll('_', ''))
  assert.ok(Number.isSafeInteger(milliseconds) && milliseconds > 0)
  return milliseconds
}

// Read the broker's source-of-truth value for deadlines, then pin the timing
// Swift will mirror so a future broker change requires an intentional update.
const AGENT_QUIET_MS = readAgentQuietMs()
assert.equal(AGENT_QUIET_MS, 4_500)

const waitTick = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

async function waitFor(predicate, description, timeoutMs = WAIT_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await predicate()
    if (value) return value
    await waitTick(20)
  }
  throw new Error(`timed out waiting for ${description}`)
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 1) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

class BrokerClient {
  constructor({ socketPath, token, instanceId, access = 'controller' }) {
    this.socketPath = socketPath
    this.token = token
    this.instanceId = instanceId
    this.access = access
    this.socket = null
    this.buffer = ''
    this.pending = new Map()
    this.events = []
    this.sequence = 0
    this.hello = null
  }

  async connect() {
    assert.equal(this.socket, null, 'client cannot connect twice')
    const socket = net.createConnection(this.socketPath)
    this.socket = socket
    socket.setNoDelay(true)

    return await new Promise((resolve, reject) => {
      let settled = false
      const finish = (callback, value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        callback(value)
      }
      const timer = setTimeout(() => {
        socket.destroy()
        finish(reject, new Error('broker hello timed out'))
      }, REQUEST_TIMEOUT_MS)

      socket.once('connect', () => {
        socket.write(`${JSON.stringify({
          type: 'hello',
          protocol: PROTOCOL,
          token: this.token,
          instanceId: this.instanceId,
          appVersion: 'agent-activity-protocol-test',
          access: this.access,
        })}\n`)
      })
      socket.on('data', (chunk) => {
        this.buffer += chunk.toString('utf8')
        let newline
        while ((newline = this.buffer.indexOf('\n')) >= 0) {
          const line = this.buffer.slice(0, newline)
          this.buffer = this.buffer.slice(newline + 1)
          if (!line) continue
          let frame
          try {
            frame = JSON.parse(line)
          } catch (error) {
            socket.destroy()
            finish(reject, error)
            continue
          }
          if (!this.hello && frame.type === 'hello') {
            if (!frame.ok) {
              socket.destroy()
              finish(reject, new Error(frame.message || 'broker hello rejected'))
            } else {
              this.hello = frame
              finish(resolve, frame)
            }
          } else if (frame.type === 'response') {
            const pending = this.pending.get(frame.id)
            if (!pending) continue
            this.pending.delete(frame.id)
            clearTimeout(pending.timer)
            if (frame.ok) pending.resolve(frame.result)
            else pending.reject(Object.assign(
              new Error(frame.message || 'broker request failed'),
              { response: frame },
            ))
          } else if (frame.type === 'event') {
            this.events.push({ ...frame, receivedAt: Date.now() })
          }
        }
      })
      socket.on('error', (error) => finish(reject, error))
      socket.on('close', () => {
        finish(reject, new Error('broker socket closed during hello'))
        for (const pending of this.pending.values()) {
          clearTimeout(pending.timer)
          pending.reject(new Error('broker socket closed'))
        }
        this.pending.clear()
      })
    })
  }

  request(method, params = {}) {
    const socket = this.socket
    if (!socket || socket.destroyed || !this.hello) {
      return Promise.reject(new Error('broker client is not connected'))
    }
    const id = `${this.instanceId}:${++this.sequence}`
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`broker request timed out: ${method}`))
      }, REQUEST_TIMEOUT_MS)
      this.pending.set(id, { resolve, reject, timer })
      socket.write(`${JSON.stringify({ type: 'request', id, method, params })}\n`, (error) => {
        if (!error) return
        const pending = this.pending.get(id)
        if (!pending) return
        this.pending.delete(id)
        clearTimeout(pending.timer)
        reject(error)
      })
    })
  }

  async close() {
    const socket = this.socket
    this.socket = null
    this.hello = null
    if (!socket || socket.destroyed) return
    await new Promise((resolve) => {
      socket.once('close', resolve)
      socket.destroy()
    })
  }
}

async function startBroker(t) {
  // Keep AF_UNIX below Darwin's short sockaddr_un limit while still using a
  // fresh OS temp directory and listener for every test.
  const root = fs.mkdtempSync('/tmp/kaap-')
  fs.chmodSync(root, 0o700)
  const socketPath = path.join(root, 'broker.sock')
  const infoFile = path.join(root, 'broker.json')
  const lockFile = path.join(root, 'broker.lock')
  const logFile = path.join(root, 'broker.log')
  const storageDir = path.join(root, 'terminal-cache')
  const launchFile = path.join(root, `launch-${crypto.randomUUID()}.json`)
  const token = crypto.randomBytes(32).toString('hex')
  const launch = {
    protocol: PROTOCOL,
    securityEpoch: SECURITY_EPOCH,
    implementationVersion: BROKER_IMPLEMENTATION_VERSION,
    packageSchema: BROKER_PACKAGE_SCHEMA,
    packageVersion: 'test',
    token,
    socketPath,
    infoFile,
    lockFile,
    storageDir,
    logFile,
    startedAt: Date.now(),
    version: 'agent-activity-protocol-test',
    smoke: false,
  }
  fs.writeFileSync(launchFile, JSON.stringify(launch), { mode: 0o600 })

  const child = spawn(process.execPath, [BROKER_SCRIPT, '--launch', launchFile], {
    cwd: root,
    env: {
      ...process.env,
      ELECTRON_RUN_AS_NODE: '1',
      KAISOLA_SESSION_BROKER: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let childOutput = ''
  let childError = null
  child.stdout.on('data', (chunk) => { childOutput += chunk.toString('utf8') })
  child.stderr.on('data', (chunk) => { childOutput += chunk.toString('utf8') })
  child.on('error', (error) => { childError = error })

  const clients = new Set()
  const terminalPids = new Set()
  let cleaningUp = false

  async function stopProcess(target, label) {
    if (!target || !pidAlive(target.pid)) return
    target.kill('SIGTERM')
    try {
      await waitFor(() => !pidAlive(target.pid), `${label} to exit`, 2_000)
    } catch {
      target.kill('SIGKILL')
      await waitFor(() => !pidAlive(target.pid), `${label} to be killed`, 2_000)
    }
  }

  async function cleanup() {
    if (cleaningUp) return
    cleaningUp = true
    for (const client of clients) {
      try { await client.close() } catch { /* best effort */ }
    }
    clients.clear()

    if (pidAlive(child.pid)) {
      let cleanupClient = null
      try {
        cleanupClient = new BrokerClient({
          socketPath,
          token,
          instanceId: crypto.randomUUID(),
        })
        await cleanupClient.connect()
        await cleanupClient.request('broker.shutdown')
      } catch {
        // The direct child fallback below is still scoped to this test broker.
      } finally {
        try { await cleanupClient?.close() } catch { /* best effort */ }
      }
    }

    try {
      await waitFor(() => !pidAlive(child.pid), 'test broker to shut down', 2_000)
    } catch {
      await stopProcess(child, 'test broker')
    }

    for (const pid of terminalPids) {
      if (!pidAlive(pid)) continue
      try { process.kill(pid, 'SIGTERM') } catch { /* already exited */ }
      try {
        await waitFor(() => !pidAlive(pid), `terminal ${pid} to exit`, 1_000)
      } catch {
        try { process.kill(pid, 'SIGKILL') } catch { /* already exited */ }
        await waitFor(() => !pidAlive(pid), `terminal ${pid} to be killed`, 1_000)
      }
    }
    fs.rmSync(root, { recursive: true, force: true })
  }
  t.after(cleanup)

  const info = await waitFor(() => {
    if (childError) throw childError
    if (child.exitCode != null) {
      let log = ''
      try { log = fs.readFileSync(logFile, 'utf8') } catch { /* absent */ }
      throw new Error(`broker exited with ${child.exitCode}: ${childOutput}${log}`)
    }
    try {
      return JSON.parse(fs.readFileSync(infoFile, 'utf8'))
    } catch {
      return null
    }
  }, 'broker info publication')
  assert.equal(info.pid, child.pid)
  assert.equal(info.socketPath, socketPath)

  return {
    root,
    terminalPids,
    async client(access = 'controller') {
      const client = new BrokerClient({
        socketPath,
        token,
        instanceId: crypto.randomUUID(),
        access,
      })
      clients.add(client)
      const hello = await client.connect()
      assert.equal(hello.pid, child.pid)
      assert.equal(hello.access, access)
      return client
    },
  }
}

function terminalParams(id, busy) {
  return {
    ownerId: 'controller-owner',
    projectId: 'agent-activity-project',
    id,
    busy,
  }
}

async function createTerminal(fixture, controller, id, args = ['-c', 'sleep 30']) {
  const created = await controller.request('terminal.create', {
    ownerId: 'controller-owner',
    projectId: 'agent-activity-project',
    id,
    command: '/bin/sh',
    args,
    cwd: fixture.root,
    cols: 80,
    rows: 24,
  })
  assert.equal(created.ok, true)
  assert.ok(Number.isInteger(created.pid) && created.pid > 1)
  fixture.terminalPids.add(created.pid)
  return created
}

async function subscribeObserver(observer, id) {
  const subscription = await observer.request('terminal.subscribe', {
    ownerId: 'swift-observer',
    projectId: 'agent-activity-project',
    id,
  })
  assert.equal(subscription.ok, true)
  return subscription
}

function activityEvents(client, channel, id) {
  return client.events.filter((event) => (
    event.channel === channel && event.payload?.id === id
  ))
}

async function waitForActivity(client, channel, id, busy, afterIndex = 0, timeoutMs = WAIT_TIMEOUT_MS) {
  return await waitFor(() => client.events.slice(afterIndex).find((event) => (
    event.channel === channel
    && event.payload?.id === id
    && event.payload?.busy === busy
  )), `${channel} busy=${busy} for ${id}`, timeoutMs)
}

test('observer receives busy activity with the exact stream cursor shape', async (t) => {
  const fixture = await startBroker(t)
  const controller = await fixture.client()
  const observer = await fixture.client('observer')
  const id = 'observer-busy'
  await createTerminal(fixture, controller, id)
  const subscription = await subscribeObserver(observer, id)
  const eventIndex = observer.events.length

  assert.deepEqual(
    await controller.request('terminal.agentTurn', terminalParams(id, true)),
    { ok: true },
  )
  const event = await waitForActivity(
    observer,
    'terminal:observer-activity',
    id,
    true,
    eventIndex,
  )

  assert.deepEqual(Object.keys(event.payload).sort(), [
    'busy',
    'completedAt',
    'id',
    'offset',
    'streamEpoch',
  ])
  assert.equal(event.payload.completedAt, null)
  assert.equal(event.payload.streamEpoch, subscription.snapshot.streamEpoch)
  assert.equal(event.payload.offset, subscription.snapshot.endOffset)
  assert.equal(typeof event.payload.streamEpoch, 'string')
  assert.ok(Number.isSafeInteger(event.payload.offset))
})

test('output rearms the broker quiet timer and auto-settles an active turn', async (t) => {
  const fixture = await startBroker(t)
  const controller = await fixture.client()
  const observer = await fixture.client('observer')
  const id = 'quiet-auto-settle'
  await createTerminal(fixture, controller, id, [
    '-c',
    'stty -echo; IFS= read -r _; printf "hi\\n"; sleep 5',
  ])
  await subscribeObserver(observer, id)

  const busyIndex = observer.events.length
  await controller.request('terminal.agentTurn', terminalParams(id, true))
  await waitForActivity(observer, 'terminal:observer-activity', id, true, busyIndex)

  // Make the output rearm observable rather than racing the timer initially
  // armed by busy:true.
  await waitTick(250)
  const outputTriggerAt = Date.now()
  await controller.request('terminal.write', {
    ...terminalParams(id, true),
    data: 'go\r',
  })
  const output = await waitFor(() => observer.events.find((event) => (
    event.channel === 'terminal:observer-output'
    && event.payload?.id === id
    && String(event.payload?.data ?? '').includes('hi')
  )), `real terminal output for ${id}`)

  const settled = await waitForActivity(
    observer,
    'terminal:observer-activity',
    id,
    false,
    busyIndex,
    AGENT_QUIET_MS + 3_000,
  )
  assert.ok(Number.isSafeInteger(settled.payload.completedAt))
  assert.ok(
    settled.payload.completedAt - outputTriggerAt >= AGENT_QUIET_MS,
    `settled before the ${AGENT_QUIET_MS}ms output-quiet interval elapsed`,
  )
  assert.ok(settled.receivedAt >= output.receivedAt)
})

test('explicit busy:false settles promptly without waiting for quiet', async (t) => {
  const fixture = await startBroker(t)
  const controller = await fixture.client()
  const observer = await fixture.client('observer')
  const id = 'explicit-settle'
  await createTerminal(fixture, controller, id)
  await subscribeObserver(observer, id)

  const busyIndex = observer.events.length
  await controller.request('terminal.agentTurn', terminalParams(id, true))
  await waitForActivity(observer, 'terminal:observer-activity', id, true, busyIndex)

  const settleIndex = observer.events.length
  const settleRequestedAt = Date.now()
  assert.deepEqual(
    await controller.request('terminal.agentTurn', terminalParams(id, false)),
    { ok: true },
  )
  const settled = await waitForActivity(
    observer,
    'terminal:observer-activity',
    id,
    false,
    settleIndex,
    1_000,
  )
  assert.ok(Number.isSafeInteger(settled.payload.completedAt))
  assert.ok(settled.payload.completedAt >= settleRequestedAt)
  assert.ok(settled.receivedAt - settleRequestedAt < AGENT_QUIET_MS)
})

test('owning controller receives terminal:agent-activity on its socket', async (t) => {
  const fixture = await startBroker(t)
  const controller = await fixture.client()
  const id = 'controller-activity'
  await createTerminal(fixture, controller, id)

  const busyIndex = controller.events.length
  await controller.request('terminal.agentTurn', terminalParams(id, true))
  const busy = await waitForActivity(
    controller,
    'terminal:agent-activity',
    id,
    true,
    busyIndex,
  )
  assert.deepEqual(Object.keys(busy.payload).sort(), ['busy', 'completedAt', 'id'])
  assert.equal(busy.ownerId, 'controller-owner')
  assert.equal(busy.projectId, 'agent-activity-project')
  assert.equal(busy.payload.completedAt, null)

  const settleIndex = controller.events.length
  await controller.request('terminal.agentTurn', terminalParams(id, false))
  const settled = await waitForActivity(
    controller,
    'terminal:agent-activity',
    id,
    false,
    settleIndex,
  )
  assert.ok(Number.isSafeInteger(settled.payload.completedAt))
})

test('busy:false while idle is an idempotent no-op with no activity event', async (t) => {
  const fixture = await startBroker(t)
  const controller = await fixture.client()
  const observer = await fixture.client('observer')
  const id = 'idle-no-op'
  await createTerminal(fixture, controller, id)
  await subscribeObserver(observer, id)
  const controllerBefore = activityEvents(controller, 'terminal:agent-activity', id).length
  const observerBefore = activityEvents(observer, 'terminal:observer-activity', id).length

  assert.deepEqual(
    await controller.request('terminal.agentTurn', terminalParams(id, false)),
    { ok: true },
  )
  await waitTick(NO_EVENT_WINDOW_MS)

  assert.equal(
    activityEvents(controller, 'terminal:agent-activity', id).length,
    controllerBefore,
  )
  assert.equal(
    activityEvents(observer, 'terminal:observer-activity', id).length,
    observerBefore,
  )
})

test('a non-owner cannot report an agent turn without explicit attach', async (t) => {
  const fixture = await startBroker(t)
  const owner = await fixture.client()
  const intruder = await fixture.client()
  const observer = await fixture.client('observer')
  const id = 'ownership-rejected'
  await createTerminal(fixture, owner, id)
  await subscribeObserver(observer, id)
  const ownerBefore = activityEvents(owner, 'terminal:agent-activity', id).length
  const intruderBefore = activityEvents(intruder, 'terminal:agent-activity', id).length
  const observerBefore = activityEvents(observer, 'terminal:observer-activity', id).length

  await assert.rejects(
    intruder.request('terminal.agentTurn', {
      ownerId: 'different-controller-owner',
      projectId: 'agent-activity-project',
      id,
      busy: true,
    }),
    (error) => {
      assert.equal(error.message, 'terminal access denied')
      assert.equal(error.response?.type, 'response')
      assert.equal(error.response?.ok, false)
      return true
    },
  )
  await waitTick(NO_EVENT_WINDOW_MS)

  assert.equal(activityEvents(owner, 'terminal:agent-activity', id).length, ownerBefore)
  assert.equal(activityEvents(intruder, 'terminal:agent-activity', id).length, intruderBefore)
  assert.equal(activityEvents(observer, 'terminal:observer-activity', id).length, observerBefore)
})
