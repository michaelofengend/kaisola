'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const { CompanionTerminalControl, MAX_TERMINAL_INPUT_BYTES } = require('./terminalControl.cjs')

function command(type, payload = {}, overrides = {}) {
  return {
    type,
    projectId: overrides.projectId ?? 'project-kaisola',
    targetId: overrides.targetId ?? 'terminal-codex',
    payload,
  }
}

function setup({ geometry = { cols: 120, rows: 42 } } = {}) {
  let now = 10_000
  let uuid = 0
  const calls = []
  const timers = new Set()
  const terminalAdapter = {
    async available(target) { calls.push({ operation: 'available', ...target }); return { ok: true, ...(geometry ? { geometry } : {}) } },
    async write(input) { calls.push({ operation: 'write', ...input }); return { ok: true } },
    async resize(input) { calls.push({ operation: 'resize', ...input }); return { ok: true } },
    async interrupt(input) { calls.push({ operation: 'interrupt', ...input }); return { ok: true } },
  }
  const control = new CompanionTerminalControl({
    terminalAdapter,
    ttlMs: 30_000,
    now: () => now,
    randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, '0')}`,
    setTimer: (callback) => {
      const timer = { callback, unref() {} }
      timers.add(timer)
      return timer
    },
    clearTimer: (timer) => timers.delete(timer),
  })
  const first = { device: { deviceId: 'device-first' }, session: { connectionId: 'connection-first' } }
  const second = { device: { deviceId: 'device-second' }, session: { connectionId: 'connection-second' } }
  return { calls, control, first, second, setNow: (value) => { now = value }, timers }
}

test('a terminal lease gates write, resize, interrupt, and releases on disconnect', async () => {
  const { calls, control, first } = setup()
  const acquired = await control.acquire({ ...first, command: command('terminal.acquire-control') })
  assert.equal(acquired.status, 'applied')
  assert.match(acquired.payload.leaseId, /^lease-/)
  assert.equal(acquired.payload.expiresAt, 40_000)
  assert.equal(acquired.payload.renewAfterMs, 10_000)
  assert.equal(acquired.payload.resizeEnabled, true)

  const payload = { leaseId: acquired.payload.leaseId }
  assert.equal((await control.write({ ...first, command: command('terminal.write', { ...payload, data: 'npm test\r' }) })).status, 'applied')
  assert.equal((await control.resize({ ...first, command: command('terminal.resize', { ...payload, cols: 92, rows: 31 }) })).status, 'applied')
  assert.equal((await control.interrupt({ ...first, command: command('terminal.interrupt', payload) })).status, 'applied')
  assert.deepEqual(calls.slice(1), [
    { operation: 'write', id: 'terminal-codex', projectId: 'project-kaisola', data: 'npm test\r' },
    { operation: 'resize', id: 'terminal-codex', projectId: 'project-kaisola', cols: 92, rows: 31 },
    { operation: 'interrupt', id: 'terminal-codex', projectId: 'project-kaisola' },
  ])
  assert.equal(await control.releaseSession(first.session), 1)
  assert.deepEqual(calls.at(-1), {
    operation: 'resize', id: 'terminal-codex', projectId: 'project-kaisola', cols: 120, rows: 42,
  })
  assert.equal(control.stats().activeLeases, 0)
  assert.equal((await control.write({ ...first, command: command('terminal.write', { ...payload, data: 'late' }) })).status, 'stale')
})

test('lease contention, expiry, and reacquisition reject every stale generation', async () => {
  const { control, first, second, setNow } = setup()
  const initial = await control.acquire({ ...first, command: command('terminal.acquire-control') })
  const denied = await control.acquire({ ...second, command: command('terminal.acquire-control') })
  assert.equal(denied.status, 'rejected')
  assert.match(denied.message, /another device/)

  setNow(initial.payload.expiresAt)
  const stale = await control.renew({
    ...first,
    command: command('terminal.renew-control', { leaseId: initial.payload.leaseId }),
  })
  assert.equal(stale.status, 'stale')

  const next = await control.acquire({ ...second, command: command('terminal.acquire-control') })
  assert.equal(next.status, 'applied')
  assert.notEqual(next.payload.leaseId, initial.payload.leaseId)
  const delayed = await control.write({
    ...first,
    command: command('terminal.write', { leaseId: initial.payload.leaseId, data: 'must-not-run' }),
  })
  assert.equal(delayed.status, 'stale')
})

test('terminal input and geometry bounds fail before reaching the adapter', async () => {
  const { calls, control, first } = setup()
  const acquired = await control.acquire({ ...first, command: command('terminal.acquire-control') })
  const leaseId = acquired.payload.leaseId
  assert.equal((await control.write({
    ...first,
    command: command('terminal.write', { leaseId, data: '' }),
  })).status, 'rejected')
  assert.equal((await control.write({
    ...first,
    command: command('terminal.write', { leaseId, data: 'x'.repeat(MAX_TERMINAL_INPUT_BYTES + 1) }),
  })).status, 'rejected')
  assert.equal((await control.resize({
    ...first,
    command: command('terminal.resize', { leaseId, cols: 19, rows: 30 }),
  })).status, 'rejected')
  assert.equal(calls.filter((entry) => entry.operation !== 'available').length, 0)
})

test('a lease is bound to both device and authenticated connection', async () => {
  const { control, first } = setup()
  const acquired = await control.acquire({ ...first, command: command('terminal.acquire-control') })
  const reconnected = { device: first.device, session: { connectionId: 'connection-replaced' } }
  const result = await control.write({
    ...reconnected,
    command: command('terminal.write', { leaseId: acquired.payload.leaseId, data: 'nope' }),
  })
  assert.equal(result.status, 'stale')
})

test('an upgrade-compatible broker permits input but withholds resize when desktop geometry is unknown', async () => {
  const { calls, control, first } = setup({ geometry: null })
  const acquired = await control.acquire({ ...first, command: command('terminal.acquire-control') })
  assert.equal(acquired.status, 'applied')
  assert.equal(acquired.payload.resizeEnabled, false)
  const resized = await control.resize({
    ...first,
    command: command('terminal.resize', { leaseId: acquired.payload.leaseId, cols: 80, rows: 24 }),
  })
  assert.equal(resized.status, 'unavailable')
  assert.equal(calls.some((entry) => entry.operation === 'resize'), false)
})
