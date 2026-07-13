const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const { AcpConnection } = require('./ipc/acp.cjs')

const invoke = async (connection, method, params) => {
  let result
  let error
  connection.respond = (_id, value) => { result = value }
  connection.respondError = (_id, code, message) => { error = { code, message } }
  await connection._handleRequest({ jsonrpc: '2.0', id: 1, method, params })
  return { result, error }
}

test('ACP file callbacks stay inside the workspace across traversal and symlinks', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-acp-root-'))
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-acp-outside-'))
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { recursive: true, force: true })
  })
  fs.writeFileSync(path.join(root, 'inside.txt'), 'inside')
  fs.writeFileSync(path.join(outside, 'secret.txt'), 'secret')
  fs.symlinkSync(outside, path.join(root, 'escape'))
  const connection = new AcpConnection({ cwd: root })

  const valid = await invoke(connection, 'fs/read_text_file', { path: 'inside.txt' })
  assert.deepEqual(valid.result, { content: 'inside' })

  const traversal = await invoke(connection, 'fs/read_text_file', { path: '../secret.txt' })
  assert.match(traversal.error.message, /outside the active workspace/)

  const symlink = await invoke(connection, 'fs/read_text_file', { path: 'escape/secret.txt' })
  assert.match(symlink.error.message, /resolves outside the active workspace/)

  const write = await invoke(connection, 'fs/write_text_file', { path: 'nested/result.txt', content: 'safe' })
  assert.deepEqual(write.result, {})
  assert.equal(fs.readFileSync(path.join(root, 'nested/result.txt'), 'utf8'), 'safe')
})

test('ACP callbacks bound file size and terminal cwd', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-acp-limits-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  let terminalCreated = false
  const connection = new AcpConnection({ cwd: root }, {
    terminalHost: { create: async () => { terminalCreated = true; return { terminalId: 'bad' } } },
  })

  const oversized = await invoke(connection, 'fs/write_text_file', {
    path: 'large.txt',
    content: 'x'.repeat((8 * 1024 * 1024) + 1),
  })
  assert.match(oversized.error.message, /exceeds/)
  assert.equal(fs.existsSync(path.join(root, 'large.txt')), false)

  const terminal = await invoke(connection, 'terminal/create', {
    command: 'pwd',
    cwd: path.dirname(root),
  })
  assert.match(terminal.error.message, /outside the active workspace/)
  assert.equal(terminalCreated, false)
})

test('ACP requests fail immediately when the adapter is disconnected', async () => {
  const connection = new AcpConnection({ cwd: os.tmpdir() })
  await assert.rejects(connection.request('initialize', {}), /not connected/)
  assert.equal(connection.pending.size, 0)
})

test('ACP terminal callbacks are isolated to the connection that created them', async () => {
  const calls = []
  let createRequest
  const terminalHost = {
    async create(request) { createRequest = request; calls.push(['create']); return { terminalId: 'acp-term-owned' } },
    async output(id) { calls.push(['output', id]); return { output: 'private' } },
    async waitForExit(id) { calls.push(['wait', id]); return { exitCode: 0 } },
    async kill(id) { calls.push(['kill', id]) },
    async release(id) { calls.push(['release', id]) },
  }
  const owner = new AcpConnection({ cwd: os.tmpdir() }, { terminalHost })
  const peer = new AcpConnection({ cwd: os.tmpdir() }, { terminalHost })

  const created = await invoke(owner, 'terminal/create', {
    command: 'true',
    cwd: os.tmpdir(),
    env: [{ name: 'KAISOLA_TEST_VALUE', value: 'mesh-ready' }, { name: 'bad-name', value: 'ignored' }],
    outputByteLimit: 0,
  })
  assert.deepEqual(created.result, { terminalId: 'acp-term-owned' })
  assert.equal(createRequest.env.KAISOLA_TEST_VALUE, 'mesh-ready')
  assert.deepEqual(Object.keys(createRequest.env), ['KAISOLA_TEST_VALUE'])
  assert.equal(createRequest.outputByteLimit, 0)

  for (const method of ['terminal/output', 'terminal/wait_for_exit', 'terminal/kill', 'terminal/release']) {
    const blocked = await invoke(peer, method, { terminalId: 'acp-term-owned' })
    assert.match(blocked.error.message, /not owned by this agent connection/)
  }
  assert.deepEqual(calls, [['create']])

  const output = await invoke(owner, 'terminal/output', { terminalId: 'acp-term-owned' })
  assert.deepEqual(output.result, { output: 'private' })
  const released = await invoke(owner, 'terminal/release', { terminalId: 'acp-term-owned' })
  assert.deepEqual(released.result, {})
  const afterRelease = await invoke(owner, 'terminal/output', { terminalId: 'acp-term-owned' })
  assert.match(afterRelease.error.message, /not owned by this agent connection/)
  assert.deepEqual(calls, [['create'], ['output', 'acp-term-owned'], ['release', 'acp-term-owned']])
})

test('disposing an ACP connection releases every terminal it still owns', async () => {
  const released = []
  const connection = new AcpConnection({ cwd: os.tmpdir() }, {
    terminalHost: {
      async create() { return { terminalId: 'acp-term-dispose' } },
      release(id) { released.push(id); return Promise.resolve() },
      kill() { throw new Error('release should succeed') },
    },
  })
  const created = await invoke(connection, 'terminal/create', { command: 'true', cwd: os.tmpdir() })
  assert.equal(created.result.terminalId, 'acp-term-dispose')
  connection.dispose()
  assert.deepEqual(released, ['acp-term-dispose'])
  assert.equal(connection.ownedTerminalIds.size, 0)
})
