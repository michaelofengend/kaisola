const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const worktree = require('./ipc/worktreeHandler.cjs')

const git = (cwd, args) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()

function repoFixture() {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-reviewed-sha-'))
  git(repo, ['init'])
  git(repo, ['config', 'user.name', 'Kaisola Test'])
  git(repo, ['config', 'user.email', 'test@kaisola.local'])
  fs.writeFileSync(path.join(repo, 'base.txt'), 'base\n')
  git(repo, ['add', 'base.txt'])
  git(repo, ['commit', '-m', 'base'])
  return repo
}

test('Mesh merges the exact reviewed commit and rejects post-review drift', async () => {
  const repo = repoFixture()
  const taskId = `reviewed-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    assert.equal(created.ok, true)
    fs.writeFileSync(path.join(created.path, 'candidate.txt'), 'reviewed\n')
    const frozen = await worktree.finalize(taskId, 'candidate', repo)
    assert.equal(frozen.ok, true)
    assert.match(frozen.sha, /^[0-9a-f]{40}$/)
    const reviewed = await worktree.diff(taskId, repo, frozen.sha)
    assert.equal(reviewed.ok, true)
    assert.equal(reviewed.sha, frozen.sha)
    assert.match(reviewed.patch, /candidate\.txt/)
    const verified = await worktree.verify(taskId, repo, frozen.sha)
    assert.deepEqual(verified, { ok: true, drifted: false, sha: frozen.sha })
    const invalidRef = await worktree.diff(taskId, repo, '--help')
    assert.equal(invalidRef.ok, false)
    assert.match(invalidRef.message, /exact commit id/)
    const invalidVerify = await worktree.verify(taskId, repo, '--help')
    assert.equal(invalidVerify.ok, false)
    assert.match(invalidVerify.message, /exact commit id/)

    fs.writeFileSync(path.join(created.path, 'after-review.txt'), 'not reviewed\n')
    const driftedPreflight = await worktree.verify(taskId, repo, frozen.sha)
    assert.equal(driftedPreflight.ok, false)
    assert.equal(driftedPreflight.drifted, true)
    const drifted = await worktree.merge(taskId, repo, frozen.sha)
    assert.equal(drifted.ok, false)
    assert.equal(drifted.drifted, true)
    assert.match(drifted.message, /changed after review/)
    assert.equal(fs.existsSync(path.join(repo, 'candidate.txt')), false)
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('Mesh accepts an unchanged reviewed commit', async () => {
  const repo = repoFixture()
  const taskId = `unchanged-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    fs.writeFileSync(path.join(created.path, 'candidate.txt'), 'reviewed\n')
    const frozen = await worktree.finalize(taskId, 'candidate', repo)
    const merged = await worktree.merge(taskId, repo, frozen.sha)
    assert.equal(merged.ok, true)
    assert.equal(fs.readFileSync(path.join(repo, 'candidate.txt'), 'utf8'), 'reviewed\n')
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('worktree cleanup retries a stale entry after the directory was already removed', async () => {
  const repo = repoFixture()
  const taskId = `cleanup-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    assert.equal(created.ok, true)
    // Simulate a prior partial cleanup: git removed/unregistered the worktree,
    // but the process failed before deleting its branch or in-memory entry.
    git(repo, ['worktree', 'remove', '--force', created.path])
    assert.equal(fs.existsSync(created.path), false)
    assert.equal(git(repo, ['show-ref', '--verify', `refs/heads/${created.branch}`]).length > 0, true)

    const removed = await worktree.remove(taskId, repo)
    assert.equal(removed.ok, true)
    assert.equal(git(repo, ['branch', '--list', created.branch]), '')
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})
