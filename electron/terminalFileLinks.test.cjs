const test = require('node:test')
const assert = require('node:assert/strict')

test('terminal output file links cover absolute, home, relative, and line paths', async () => {
  const { terminalFileLinkCandidates } = await import('../src/lib/terminalFileLinks.ts')
  const links = terminalFileLinkCandidates('See /Users/me/work/report.md:42, ~/notes/today.md and src/main.ts:7:3.')
  assert.deepEqual(links.map(({ path, line, column }) => ({ path, line, column })), [
    { path: '/Users/me/work/report.md', line: 42, column: undefined },
    { path: '~/notes/today.md', line: undefined, column: undefined },
    { path: 'src/main.ts', line: 7, column: 3 },
  ])
})

test('terminal output file links ignore web URLs and trim prose punctuation', async () => {
  const { terminalFileLinkCandidates } = await import('../src/lib/terminalFileLinks.ts')
  const links = terminalFileLinkCandidates('Open https://example.com/a/b and (./local/file.py#L9).')
  assert.equal(links.length, 1)
  assert.equal(links[0].text, './local/file.py#L9')
  assert.equal(links[0].path, './local/file.py')
  assert.equal(links[0].line, 9)
})

test('terminal output file links recognize a bare filename without linking ordinary prose', async () => {
  const { terminalFileLinkCandidates } = await import('../src/lib/terminalFileLinks.ts')
  const links = terminalFileLinkCandidates('Wrote 82 lines to fig5_selfscore_pooled.py. Nothing else pending.')
  assert.deepEqual(links.map((link) => link.path), ['fig5_selfscore_pooled.py'])
})
