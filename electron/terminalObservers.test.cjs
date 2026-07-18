'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const { MAX_TERMINAL_OBSERVERS, TerminalObservers } = require('./ipc/terminalObservers.cjs')

test('observer backpressure emits one reset marker then discards deltas until resubscribe', () => {
  const frames = []
  let congested = true
  const observers = new TerminalObservers({
    terminalId: 'terminal-1',
    deliver: (owner, channel, payload, options) => {
      frames.push({ owner, channel, payload, options })
      return options.force || !congested
    },
  })
  observers.subscribe('instance|phone|project-a', { maxQueueBytes: 8 })
  observers.broadcast('terminal:observer-output', { data: 'first' }, { streamEpoch: 'stream-1', endOffset: 5 })
  observers.broadcast('terminal:observer-output', { data: 'discarded' }, { streamEpoch: 'stream-1', endOffset: 14 })
  assert.deepEqual(frames.map(({ channel }) => channel), [
    'terminal:observer-output',
    'terminal:observer-snapshot-required',
  ])
  assert.deepEqual(observers.stats(), { subscribers: 1, paused: 1 })

  congested = false
  observers.subscribe('instance|phone|project-a')
  observers.broadcast('terminal:observer-output', { data: 'resumed' }, { streamEpoch: 'stream-1', endOffset: 21 })
  assert.equal(frames.at(-1).payload.data, 'resumed')
  assert.deepEqual(observers.stats(), { subscribers: 1, paused: 0 })
})

test('subscriber cleanup is exact and prefix-bounded', () => {
  const observers = new TerminalObservers({ terminalId: 'terminal-1', deliver: () => true })
  observers.subscribe('instance-a|one|project-a')
  observers.subscribe('instance-a|two|project-a')
  observers.subscribe('instance-b|one|project-a')
  assert.equal(observers.unsubscribe('instance-a|one|project-a'), true)
  assert.equal(observers.unsubscribePrefix('instance-a|'), 1)
  assert.deepEqual(observers.stats(), { subscribers: 1, paused: 0 })
})

test('broker authority caps each terminal at eight observers while allowing exact resubscribe', () => {
  const observers = new TerminalObservers({ terminalId: 'terminal-cap', deliver: () => true })
  for (let index = 0; index < MAX_TERMINAL_OBSERVERS; index++) observers.subscribe(`observer-${index}`)
  assert.deepEqual(observers.stats(), { subscribers: MAX_TERMINAL_OBSERVERS, paused: 0 })
  assert.doesNotThrow(() => observers.subscribe('observer-0'))
  assert.throws(() => observers.subscribe('observer-over-cap'), /observer limit of 8 reached/)
  assert.equal(observers.unsubscribe('observer-7'), true)
  assert.doesNotThrow(() => observers.subscribe('observer-after-release'))
})
