'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { TerminalSpool, utf8Tail } = require('./ipc/terminalSpool.cjs')

test('UTF-8 tail truncation never begins inside an emoji', () => {
  assert.equal(utf8Tail('abc🙂\r\n', 6), '🙂\r\n')
  assert.equal(utf8Tail('abc🙂\r\n', 5), '\r\n')
})

test('a fresh terminal stream cannot inherit stale bytes from a dead PTY', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-test-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const old = new TerminalSpool({ dir, id: 'same-terminal', hotCap: 8, queueCap: 1 })
  old.push('old output')
  old.setVisible(false)
  old.close()
  assert.match(new TerminalSpool({ dir, id: 'same-terminal' }).snapshot().output, /old output/)
  assert.equal(new TerminalSpool({ dir, id: 'same-terminal', fresh: true }).snapshot().output, '')
})

// Bracketed paste (?2004) and friends live outside the byte stream: when the
// enable sequence scrolls past the bounded tail, a reattached renderer must
// still learn the mode or multi-line pastes submit line-by-line.
test('private DEC modes survive tail truncation via modePrefix, not output bytes', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-test-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const spool = new TerminalSpool({ dir, id: 'modes', hotCap: 64, queueCap: 32 })
  spool.push('\x1b[?2004h\x1b[?1h')
  spool.push('x'.repeat(4096)) // push the enables far past any snapshot cap
  const snap = spool.snapshot(64)
  assert.ok(!snap.output.includes('\x1b[?2004h'), 'enable sequence is outside the tail')
  assert.match(snap.modePrefix, /\x1b\[\?2004h/)
  assert.match(snap.modePrefix, /\x1b\[\?1h/)
})

test('a mode reset drops it from the prefix and defaults are never replayed', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-test-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const spool = new TerminalSpool({ dir, id: 'modes-reset', hotCap: 64, queueCap: 32 })
  spool.push('\x1b[?2004h\x1b[?25l')
  spool.push('\x1b[?2004l') // app turned bracketed paste back off
  spool.push('x'.repeat(4096))
  const snap = spool.snapshot(64)
  assert.ok(!/\x1b\[\?2004[hl]/.test(snap.modePrefix), 'default-state modes are omitted')
  assert.match(snap.modePrefix, /\x1b\[\?25l/, 'hidden cursor is non-default and replayed')
})

test('mode sequences split across push chunks and multi-param lists still track', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-spool-test-'))
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const spool = new TerminalSpool({ dir, id: 'modes-split', hotCap: 64, queueCap: 32 })
  spool.push('\x1b[?20')
  spool.push('04h') // split mid-sequence at a chunk boundary
  spool.push('\x1b[?1006;1002h') // multi-param DECSET
  spool.push('\x1b[?9999h') // untracked mode never replays
  spool.push('x'.repeat(4096))
  const snap = spool.snapshot(64)
  assert.match(snap.modePrefix, /\x1b\[\?2004h/)
  assert.match(snap.modePrefix, /\x1b\[\?1002h/)
  assert.match(snap.modePrefix, /\x1b\[\?1006h/)
  assert.ok(!snap.modePrefix.includes('9999'), 'untracked modes are not replayed')
})

