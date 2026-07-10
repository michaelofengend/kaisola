const test = require('node:test')
const assert = require('node:assert/strict')
const { boundedCount, safeNotice } = require('./ipc/attentionHandler.cjs')

test('native attention counts are finite non-negative dock badge values', () => {
  assert.equal(boundedCount(-2), 0)
  assert.equal(boundedCount(4.9), 4)
  assert.equal(boundedCount('12'), 12)
  assert.equal(boundedCount(Infinity), 0)
  assert.equal(boundedCount(5_000), 999)
})

test('native notification payloads are bounded and carry safe navigation ids', () => {
  assert.equal(safeNotice(null), null)
  assert.equal(safeNotice({ title: '   ' }), null)
  assert.deepEqual(safeNotice({
    title: ' Codex finished ',
    body: 'Ready to review',
    projectId: 'project-1',
    sessionId: 'thread-1',
  }), {
    title: 'Codex finished',
    body: 'Ready to review',
    projectId: 'project-1',
    sessionId: 'thread-1',
  })
})
