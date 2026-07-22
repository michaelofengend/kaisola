const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { Duplex } = require('node:stream')
const {
  OBSERVER_METHODS,
  observerMethodAllowed,
  brokerMethodAllowedForAccess,
} = require('./ipc/brokerWire.cjs')

const {
  SessionBrokerClient,
  PROTOCOL,
  SECURITY_EPOCH,
  TERMINAL_OBSERVE_FEATURE,
  __test: { LEGACY_UNSCOPED_PROTOCOL, requestBrokerControl, validateBrokerHello, pidAlive, unixSocketPath },
} = require('./ipc/sessionBrokerClient.cjs')

const TOKEN = 'a'.repeat(64)

test('observer broker policy exposes only the coexistence read surface', () => {
  assert.deepEqual(OBSERVER_METHODS, [
    'broker.status',
    'terminal.list',
    'terminal.diagnostics',
    'terminal.subscribe',
    'terminal.unsubscribe',
  ])
  for (const method of OBSERVER_METHODS) assert.equal(observerMethodAllowed(method), true)
  for (const method of [
    'broker.shutdown',
    'terminal.create',
    'terminal.attach',
    'terminal.detachRenderer',
    'terminal.detachOwner',
    'terminal.write',
    'terminal.agentTurn',
    'terminal.resize',
    'terminal.snapshot',
    'terminal.output',
    'terminal.waitForExit',
    'terminal.signal',
    'terminal.kill',
    'terminal.release',
    'terminal.scheduleRelease',
    'terminal.cancelRelease',
    'terminal.setFocused',
  ]) assert.equal(observerMethodAllowed(method), false, method)
  for (const method of OBSERVER_METHODS) {
    assert.equal(brokerMethodAllowedForAccess('observer', method), true, method)
  }
  assert.equal(brokerMethodAllowedForAccess('observer', 'terminal.write'), false)
  assert.equal(brokerMethodAllowedForAccess('controller', 'terminal.write'), true)
  assert.equal(brokerMethodAllowedForAccess(undefined, 'terminal.write'), true)
})

function clientFixture(t) {
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-broker-client-test-'))
  t.after(() => fs.rmSync(userData, { recursive: true, force: true }))
  return new SessionBrokerClient({
    userData,
    execPath: process.execPath,
    brokerScript: path.join(__dirname, 'session-broker.cjs'),
    appVersion: 'test-version',
  })
}

function writeInfo(client, overrides = {}) {
  const info = {
    protocol: PROTOCOL,
    securityEpoch: SECURITY_EPOCH,
    pid: process.pid,
    socketPath: client.socketPath,
    token: TOKEN,
    startedAt: Date.now(),
    version: 'test-version',
    ...overrides,
  }
  fs.mkdirSync(client.root, { recursive: true })
  fs.writeFileSync(client.infoFile, JSON.stringify(info))
  return info
}

test('current broker handshake requires the project-isolation security epoch', () => {
  const info = { pid: 42 }
  const valid = { type: 'hello', ok: true, protocol: PROTOCOL, securityEpoch: SECURITY_EPOCH, pid: 42 }
  assert.equal(validateBrokerHello(valid, info), valid)
  assert.throws(
    () => validateBrokerHello({ ...valid, securityEpoch: undefined }, info),
    /project-scoped terminal isolation/,
  )
  assert.throws(
    () => validateBrokerHello({ ...valid, protocol: LEGACY_UNSCOPED_PROTOCOL }, info),
    /not supported/,
  )
  assert.throws(
    () => validateBrokerHello({ ...valid, pid: 43 }, info),
    /identity changed/,
  )
})

test('new Unix brokers use a durable private path rather than the OS temp directory', (t) => {
  const client = clientFixture(t)
  if (process.platform === 'win32') return
  assert.equal(client.socketPath.startsWith(os.tmpdir()), false)
  assert.ok(
    client.socketPath === path.join(client.root, 'broker.sock')
      || client.socketPath.startsWith(path.join(os.homedir(), '.kaisola-session', path.sep)),
  )
  assert.equal(
    unixSocketPath('/Users/example/Library/Application Support/pasola', 'c'.repeat(18), '/Users/example'),
    '/Users/example/Library/Application Support/pasola/session-broker/broker.sock',
  )
})

test('long user-data paths use a compact durable home socket instead of OS temp', () => {
  const digest = 'b'.repeat(18)
  const userData = path.join('/Users/example', 'x'.repeat(140))
  const homeDir = '/Users/example'
  assert.equal(unixSocketPath(userData, digest, homeDir), path.join(homeDir, '.kaisola-session', `${digest}.sock`))
})

test('EPERM process visibility is treated as alive so live broker state is never unlinked', () => {
  const denied = Object.assign(new Error('operation not permitted'), { code: 'EPERM' })
  assert.equal(pidAlive(42, () => { throw denied }), true)
  assert.equal(pidAlive(42, () => { throw Object.assign(new Error('missing'), { code: 'ESRCH' }) }), false)
})

test('a live protocol-2 broker on the legacy temp socket is adopted in place', async (t) => {
  const client = clientFixture(t)
  const legacySocketPath = path.join(os.tmpdir(), `kaisola-legacy-${process.pid}.sock`)
  const info = writeInfo(client, { socketPath: legacySocketPath, version: '0.1.60' })
  let spawned = false
  client._open = async (opened) => {
    assert.deepEqual(opened, info)
    client.hello = { ok: true, protocol: PROTOCOL, securityEpoch: SECURITY_EPOCH, pid: info.pid }
  }
  client._spawn = async () => { spawned = true }

  const hello = await client.connect()
  assert.equal(hello.pid, process.pid)
  assert.equal(spawned, false)
  assert.equal(client.socketPath.startsWith(os.tmpdir()), false)
})

test('renderer crash forgets only event routing, not broker terminal ownership', (t) => {
  const client = clientFixture(t)
  const sender = { id: 77, isDestroyed: () => false }
  client.registerOwner(sender)
  assert.equal(client.owners.get('77'), sender)
  assert.deepEqual(client.forgetOwner(sender), { ok: true })
  assert.equal(client.owners.has('77'), false)
})

test('terminal observation is used only when the live broker advertises it', (t) => {
  const client = clientFixture(t)
  client.hello = { features: [TERMINAL_OBSERVE_FEATURE] }
  assert.equal(client.supports(TERMINAL_OBSERVE_FEATURE), true)
  client.hello = { features: [] }
  assert.equal(client.supports(TERMINAL_OBSERVE_FEATURE), false)
})

test('legacy retirement control authenticates with protocol 1 and only requests shutdown', async () => {
  const writes = []
  const createConnection = () => {
    let socket
    socket = new Duplex({
      read() {},
      write(chunk, _encoding, callback) {
        try {
          for (const line of String(chunk).trim().split('\n')) {
            if (!line) continue
            const frame = JSON.parse(line)
            writes.push(frame)
            if (frame.type === 'hello') {
              queueMicrotask(() => socket.push(`${JSON.stringify({
                type: 'hello', ok: true, protocol: LEGACY_UNSCOPED_PROTOCOL, pid: 123, version: '0.1.59',
              })}\n`))
            } else if (frame.type === 'request') {
              queueMicrotask(() => socket.push(`${JSON.stringify({
                type: 'response', id: frame.id, ok: true, result: { ok: true },
              })}\n`))
            }
          }
          callback()
        } catch (error) { callback(error) }
      },
    })
    socket.setNoDelay = () => socket
    queueMicrotask(() => socket.emit('connect'))
    return socket
  }

  const result = await requestBrokerControl(
    { socketPath: 'test-socket', token: TOKEN },
    {
      protocol: LEGACY_UNSCOPED_PROTOCOL,
      appVersion: 'next-version',
      method: 'broker.shutdown',
      timeoutMs: 1_000,
      createConnection,
    },
  )

  assert.deepEqual(result, { ok: true })
  assert.equal(writes.length, 2)
  assert.deepEqual(
    { type: writes[0].type, protocol: writes[0].protocol, token: writes[0].token, appVersion: writes[0].appVersion },
    { type: 'hello', protocol: LEGACY_UNSCOPED_PROTOCOL, token: TOKEN, appVersion: 'next-version' },
  )
  assert.deepEqual(
    { type: writes[1].type, method: writes[1].method, params: writes[1].params },
    { type: 'request', method: 'broker.shutdown', params: {} },
  )
})

test('connect retires a live protocol-1 broker before spawning protocol 2', async (t) => {
  const client = clientFixture(t)
  writeInfo(client, { protocol: LEGACY_UNSCOPED_PROTOCOL, securityEpoch: undefined })
  const order = []
  client._open = async () => { throw new Error('legacy broker must never be opened as the active transport') }
  client._retireLegacyBroker = async (info) => {
    assert.equal(info.protocol, LEGACY_UNSCOPED_PROTOCOL)
    order.push('retire')
    fs.unlinkSync(client.infoFile)
  }
  client._spawn = async () => {
    order.push('spawn')
    client.hello = { ok: true, protocol: PROTOCOL, securityEpoch: SECURITY_EPOCH, pid: 999 }
  }

  const hello = await client.connect()
  assert.deepEqual(order, ['retire', 'spawn'])
  assert.equal(hello.protocol, PROTOCOL)
  assert.equal(hello.securityEpoch, SECURITY_EPOCH)
})

test('legacy migration adopts a protocol-2 broker won by another app instance', async (t) => {
  const client = clientFixture(t)
  writeInfo(client, { protocol: LEGACY_UNSCOPED_PROTOCOL, securityEpoch: undefined })
  const replacement = {
    protocol: PROTOCOL,
    securityEpoch: SECURITY_EPOCH,
    pid: process.pid,
    socketPath: 'replacement-socket',
    token: 'b'.repeat(64),
    startedAt: Date.now() + 1,
    version: 'other-app-version',
  }
  const order = []
  client._retireLegacyBroker = async () => {
    order.push('retire')
    fs.writeFileSync(client.infoFile, JSON.stringify(replacement))
  }
  client._open = async (info) => {
    order.push('adopt')
    assert.deepEqual(info, replacement)
    client.hello = { ok: true, protocol: PROTOCOL, securityEpoch: SECURITY_EPOCH, pid: replacement.pid }
  }
  client._spawn = async () => { throw new Error('must not compete with replacement broker') }

  const hello = await client.connect()
  assert.deepEqual(order, ['retire', 'adopt'])
  assert.equal(hello.pid, replacement.pid)
})

test('failed legacy retirement fails closed and never starts a competing broker', async (t) => {
  const client = clientFixture(t)
  writeInfo(client, { protocol: LEGACY_UNSCOPED_PROTOCOL, securityEpoch: undefined })
  let spawned = false
  client._retireLegacyBroker = async () => { throw new Error('authenticated shutdown failed') }
  client._spawn = async () => { spawned = true }

  await assert.rejects(client.connect(), /authenticated shutdown failed/)
  assert.equal(spawned, false)
  assert.equal(client.hello, null)
})

test('unknown live protocols are neither adopted nor terminated', async (t) => {
  const client = clientFixture(t)
  writeInfo(client, { protocol: 99, securityEpoch: 99 })
  let opened = false
  let retired = false
  let spawned = false
  client._open = async () => { opened = true }
  client._retireLegacyBroker = async () => { retired = true }
  client._spawn = async () => { spawned = true }

  await assert.rejects(client.connect(), /unsupported live session broker protocol 99/)
  assert.deepEqual({ opened, retired, spawned }, { opened: false, retired: false, spawned: false })
})
