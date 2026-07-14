const test = require('node:test')
const assert = require('node:assert/strict')
const os = require('node:os')
const path = require('node:path')
const { resolveUserPath } = require('./ipc/pathResolver.cjs')

test('terminal file paths resolve from cwd and expand the user home', () => {
  assert.equal(resolveUserPath('src/main.ts', '/tmp/project'), path.join('/tmp/project', 'src/main.ts'))
  assert.equal(resolveUserPath('~/notes.md', '/tmp/project'), path.join(os.homedir(), 'notes.md'))
  assert.equal(resolveUserPath('/tmp/file.md', '/elsewhere'), path.normalize('/tmp/file.md'))
  assert.equal(resolveUserPath('\0bad', '/tmp'), null)
})
