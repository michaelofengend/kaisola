const test = require('node:test')
const assert = require('node:assert/strict')

const moduleUrl = new URL('../src/lib/terminalResidency.ts', `file://${__filename}`)

test('hidden terminal residency defaults to a bounded warm LRU', async () => {
  const values = new Map()
  global.localStorage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
  }
  const residency = await import(moduleUrl.href)

  assert.equal(residency.defaultHiddenTerminalResidentCap('eco'), 2)
  assert.equal(residency.defaultHiddenTerminalResidentCap('glass'), 4)
  assert.equal(residency.hiddenTerminalResidentCap('eco'), 2)
  assert.equal(residency.hiddenTerminalResidentCap('glass'), 4)

  values.set('kaisola:hidden-terminal-residents', '0')
  assert.equal(residency.hiddenTerminalResidentCap('glass'), 0, 'an explicit memory-saving choice is preserved')

  values.set('kaisola:hidden-terminal-residents', '99')
  assert.equal(residency.hiddenTerminalResidentCap('eco'), 8, 'resident canvases stay bounded')
})
