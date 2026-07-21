'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  __test: {
    advanceLegacyTerminalSnapshot,
    legacyTerminalOverlap,
    legacyTerminalSnapshot,
  },
} = require('./ipc/terminalHandler.cjs')

test('legacy broker output becomes a bounded cursor snapshot instead of unavailable', () => {
  const normalized = legacyTerminalSnapshot({
    output: 'before update\r\nstill running',
    truncated: true,
    exited: false,
  }, 'legacy-fixed')
  assert.equal(normalized.snapshot.streamEpoch, 'legacy-fixed')
  assert.equal(normalized.snapshot.endOffset, Buffer.byteLength('before update\r\nstill running'))
  assert.equal(normalized.snapshot.truncated, true)
  assert.equal(normalized.snapshot.exited, false)
})

test('legacy polling emits only appended bytes while its retained window grows', () => {
  const first = legacyTerminalSnapshot({ output: 'alpha', exited: false }, 'legacy-grow')
  const next = advanceLegacyTerminalSnapshot(first.state, { output: 'alpha beta', exited: false }, 'unused')
  assert.equal(next.state.streamEpoch, 'legacy-grow')
  assert.deepEqual(next.event, {
    channel: 'terminal:observer-output',
    payload: {
      streamEpoch: 'legacy-grow',
      data: ' beta',
      startOffset: 5,
      endOffset: 10,
    },
  })
})

test('legacy rolling snapshots recover suffix-prefix overlap without duplicate replay', () => {
  const previous = Buffer.from('0123456789')
  const next = Buffer.from('456789abc')
  assert.equal(legacyTerminalOverlap(previous, next), 6)

  const first = legacyTerminalSnapshot({ output: previous.toString(), truncated: true, exited: false }, 'legacy-roll')
  const advanced = advanceLegacyTerminalSnapshot(first.state, { output: next.toString(), truncated: true, exited: false }, 'unused')
  assert.equal(advanced.event.channel, 'terminal:observer-output')
  assert.equal(advanced.event.payload.data, 'abc')
  assert.equal(advanced.event.payload.startOffset, 10)
  assert.equal(advanced.event.payload.endOffset, 13)
})

test('legacy replacement resets the stream epoch instead of concatenating unrelated bytes', () => {
  const first = legacyTerminalSnapshot({ output: 'old terminal bytes', exited: false }, 'legacy-old')
  const reset = advanceLegacyTerminalSnapshot(first.state, { output: 'completely new', exited: false }, 'legacy-new')
  assert.equal(reset.state.streamEpoch, 'legacy-new')
  assert.equal(reset.event.channel, 'terminal:observer-snapshot')
  assert.equal(reset.event.payload.output, 'completely new')
  assert.equal(reset.event.payload.endOffset, Buffer.byteLength('completely new'))
})

test('legacy exit state is delivered even when no final output byte was added', () => {
  const first = legacyTerminalSnapshot({ output: 'done', exited: false }, 'legacy-exit')
  const exited = advanceLegacyTerminalSnapshot(first.state, {
    output: 'done',
    exited: true,
    exitStatus: { exitCode: 0, signal: null },
  }, 'unused')
  assert.equal(exited.event.channel, 'terminal:observer-snapshot')
  assert.equal(exited.event.payload.exited, true)
  assert.deepEqual(exited.event.payload.exitStatus, { exitCode: 0, signal: null })
})
