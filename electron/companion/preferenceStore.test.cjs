'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const { CompanionPreferenceStore } = require('./preferenceStore.cjs')

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-preferences-'))
  const filePath = path.join(directory, 'companion', 'settings.json')
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  return { filePath, store: new CompanionPreferenceStore({ filePath }) }
}

test('first upgraded launch can default Companion on for an already-paired device', (t) => {
  const { filePath, store } = fixture(t)
  assert.deepEqual(store.load({ defaultEnabled: true }), { enabled: true })
  assert.deepEqual(JSON.parse(fs.readFileSync(filePath, 'utf8')), { v: 1, enabled: true })
  if (process.platform !== 'win32') assert.equal(fs.statSync(filePath).mode & 0o777, 0o600)
})

test('an explicit off choice wins over later migration defaults', (t) => {
  const { filePath, store } = fixture(t)
  store.load({ defaultEnabled: true })
  store.setEnabled(false)
  const reloaded = new CompanionPreferenceStore({ filePath })
  assert.deepEqual(reloaded.load({ defaultEnabled: true }), { enabled: false })
})

test('invalid preference files fail closed without preventing app startup', (t) => {
  const { filePath } = fixture(t)
  fs.mkdirSync(path.dirname(filePath), { recursive: true })
  const invalid = JSON.stringify({ v: 1, enabled: 'yes' })
  fs.writeFileSync(filePath, invalid)
  const store = new CompanionPreferenceStore({ filePath })
  assert.deepEqual(store.load({ defaultEnabled: true }), { enabled: false })
  assert.equal(fs.readFileSync(filePath, 'utf8'), invalid, 'recovery preserves the invalid file until an explicit choice')
  assert.deepEqual(store.setEnabled(true), { enabled: true })
  assert.deepEqual(JSON.parse(fs.readFileSync(filePath, 'utf8')), { v: 1, enabled: true })
})
