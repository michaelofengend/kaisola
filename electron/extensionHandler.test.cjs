const test = require('node:test')
const assert = require('node:assert/strict')
const { sanitizeManifest } = require('./ipc/extensionHandler.cjs')

const base = (contributions) => ({
  id: 'example.extension',
  name: 'Example extension',
  version: '1.0.0',
  contributions,
})

test('main manifest authority accepts bounded declarative contributions', () => {
  const manifest = sanitizeManifest(base({
    languages: [{ id: 'notes', name: 'Notes', extensions: ['note'], grammar: { lineComments: ['#'] } }],
    previews: [{ id: 'notes-preview', name: 'Notes preview', extensions: ['note'], renderer: 'markdown' }],
  }), '/tmp/example-extension')
  assert.equal(manifest.sourcePath, '/tmp/example-extension')
  assert.equal(manifest.contributions.languages[0].extensions[0], 'note')
  assert.equal(manifest.contributions.previews[0].renderer, 'markdown')
})

test('main manifest authority rejects executable and unsafe remote shapes', () => {
  assert.throws(() => sanitizeManifest(base({ mcpServers: [{ name: 'bad', config: { url: 'http://remote.example/mcp' } }] })), /No supported/)
  const local = sanitizeManifest(base({ mcpServers: [{ name: 'local', config: { url: 'http://127.0.0.1:8787/mcp' } }] }))
  assert.equal(local.contributions.mcpServers[0].config.url, 'http://127.0.0.1:8787/mcp')
  const ignoredRuntime = sanitizeManifest({ ...base({ languages: [{ extensions: ['x'], grammar: {} }] }), main: './index.js' })
  assert.equal(Object.prototype.hasOwnProperty.call(ignoredRuntime, 'main'), false)
})
