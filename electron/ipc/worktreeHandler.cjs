// Git worktree isolation for file-mutating (coding) agents. Each coding task
// gets its OWN git worktree + branch, so parallel agents never touch the same
// files. When the agent finishes, the branch diff is surfaced as a Proposal
// (file-patch); approving it merges the branch back — the Proposal gate becomes
// the merge gate. Pure local git via child_process: ZERO model/API cost.
//
// Lifecycle: create → (agent writes in the worktree cwd) → finalize (commit) →
//   diff (→ file-patch Proposal) → merge (on approve) → remove.
//
// Exposes registerWorktreeHandlers(ipcMain) for the app AND the raw async
// functions for the headless smoke harness to drive against a temp repo.
const { execFile } = require('child_process')
const path = require('path')

const WT_DIR = '.pasola-worktrees'
const isCommitId = (value) => typeof value === 'string' && /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(value)
// taskId → { repo, path, branch, base, baseBranch } — session state for diff/merge.
const worktrees = new Map()

function git(cwd, args) {
  return new Promise((resolve) => {
    execFile('git', args, { cwd, maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ ok: !err, code: err ? err.code ?? 1 : 0, stdout: stdout ?? '', stderr: stderr ?? '' })
    })
  })
}

async function create(repo, taskId) {
  if (worktrees.has(taskId)) return { ok: false, message: `worktree ${taskId} already exists` }
  const branch = `pz/${taskId}`
  const rel = path.join(WT_DIR, taskId)
  const base = (await git(repo, ['rev-parse', 'HEAD'])).stdout.trim()
  const baseBranch = (await git(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).stdout.trim()
  if (!base) return { ok: false, message: 'not a git repository (or it has no commits yet)' }
  const r = await git(repo, ['worktree', 'add', '-b', branch, rel])
  if (!r.ok) return { ok: false, message: (r.stderr || r.stdout).trim() || 'worktree add failed' }
  const wtPath = path.join(repo, rel)
  worktrees.set(taskId, { repo, path: wtPath, branch, base, baseBranch })
  return { ok: true, path: wtPath, branch, base }
}

// The Map is in-memory but worktrees are DISK state that outlives the app.
// Callers that persisted a taskId pass `repo` along; the entry rebuilds from
// the deterministic layout (repo/.pasola-worktrees/<taskId>, branch pz/<id>).
async function rehydrate(taskId, repo) {
  if (worktrees.has(taskId) || !repo) return worktrees.get(taskId)
  const fs = require('fs')
  const wtPath = path.join(repo, WT_DIR, taskId)
  if (!fs.existsSync(wtPath)) return undefined
  const branch = `pz/${taskId}`
  const base = (await git(repo, ['merge-base', 'HEAD', branch])).stdout.trim()
  const baseBranch = (await git(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])).stdout.trim()
  const entry = { repo, path: wtPath, branch, base, baseBranch }
  worktrees.set(taskId, entry)
  return entry
}

async function finalize(taskId, message, repo) {
  const wt = worktrees.get(taskId) ?? (await rehydrate(taskId, repo))
  if (!wt) return { ok: false, message: 'unknown worktree' }
  const added = await git(wt.path, ['add', '-A'])
  // a FAILED stage (stale .git/index.lock, disk-full, permissions) must fail
  // loudly too — otherwise `diff --cached` below sees nothing staged and we'd
  // merge the branch WITHOUT the agent's newest edits while toasting success.
  if (!added.ok) return { ok: false, message: (added.stderr || added.stdout).trim().slice(0, 300) || 'git add failed in the worktree' }
  // nothing staged = nothing to commit = fine. But a FAILED commit of real
  // changes must fail loudly — merging the stale branch would drop them.
  const staged = await git(wt.path, ['diff', '--cached', '--quiet'])
  let committed = false
  if (!staged.ok) {
    const c = await git(wt.path, ['commit', '-m', message || `pasola: ${taskId}`])
    if (!c.ok) return { ok: false, message: (c.stderr || c.stdout).trim().slice(0, 300) || 'commit failed in the worktree' }
    committed = true
  }
  const head = await git(wt.path, ['rev-parse', 'HEAD'])
  if (!head.ok || !head.stdout.trim()) return { ok: false, message: 'could not resolve the frozen candidate commit' }
  return { ok: true, committed, sha: head.stdout.trim() }
}

async function diff(taskId, repo, ref) {
  const wt = worktrees.get(taskId) ?? (await rehydrate(taskId, repo))
  if (!wt) return { ok: false, message: 'unknown worktree' }
  if (ref && !isCommitId(ref)) return { ok: false, message: 'review candidate must be an exact commit id' }
  const target = ref || wt.branch
  const resolved = await git(wt.repo, ['rev-parse', '--verify', `${target}^{commit}`])
  if (!resolved.ok) return { ok: false, message: 'review candidate commit no longer exists' }
  const sha = resolved.stdout.trim()
  const patch = await git(wt.repo, ['diff', wt.base, sha])
  const ns = await git(wt.repo, ['diff', '--numstat', wt.base, sha])
  const files = ns.stdout
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const [add, del, p] = line.split('\t')
      return { path: p, additions: Number(add) || 0, deletions: Number(del) || 0 }
    })
  return { ok: true, patch: patch.stdout, files, sha }
}

/** Preflight every frozen candidate before the first merge mutates main. This
 * keeps a multi-member integration atomic with respect to the common case of a
 * worker changing after review; merge() repeats the check to close the race. */
async function verify(taskId, repo, ref) {
  const wt = worktrees.get(taskId) ?? (await rehydrate(taskId, repo))
  if (!wt) return { ok: false, message: 'unknown worktree' }
  if (!isCommitId(ref)) return { ok: false, drifted: false, message: 'review candidate must be an exact commit id' }
  const resolved = await git(wt.repo, ['rev-parse', '--verify', `${ref}^{commit}`])
  if (!resolved.ok) return { ok: false, drifted: false, message: 'review candidate commit no longer exists' }
  const head = await git(wt.path, ['rev-parse', 'HEAD'])
  const workerStatus = await git(wt.path, ['status', '--porcelain'])
  if (!head.ok || head.stdout.trim() !== ref || workerStatus.stdout.trim()) {
    return { ok: false, drifted: true, message: 'candidate changed after review — cross-review it again before integration' }
  }
  return { ok: true, drifted: false, sha: resolved.stdout.trim() }
}

async function merge(taskId, repo, ref) {
  const wt = worktrees.get(taskId) ?? (await rehydrate(taskId, repo))
  if (!wt) return { ok: false, message: 'unknown worktree' }
  if (ref && !isCommitId(ref)) return { ok: false, conflicted: false, message: 'review candidate must be an exact commit id' }
  // refuse to merge into a detached HEAD — the merge commit would advance no
  // branch ref and be lost on the next checkout.
  const sym = await git(wt.repo, ['symbolic-ref', '-q', 'HEAD'])
  if (!sym.ok) return { ok: false, conflicted: false, message: 'base repo is in detached HEAD — check out a branch first' }
  // refuse to merge into a dirty working tree — but only TRACKED changes (a merge
  // can't clobber untracked files, and the .pasola-worktrees/ dir itself is
  // untracked, so -uno avoids a false positive).
  const status = await git(wt.repo, ['status', '--porcelain', '--untracked-files=no'])
  if (status.stdout.trim()) return { ok: false, conflicted: false, message: 'base repo has uncommitted changes — commit or stash them first' }
  const target = ref || wt.branch
  if (ref) {
    const frozen = await verify(taskId, repo, ref)
    if (!frozen.ok) return { ...frozen, conflicted: false }
  }
  const m = await git(wt.repo, ['merge', '--no-ff', '-m', `pasola merge ${taskId}`, target])
  if (!m.ok) {
    const conflicted = /conflict/i.test(`${m.stdout}${m.stderr}`)
    // ALWAYS abort on failure (a no-op if no merge is in progress) so the base
    // repo is never left half-merged, regardless of git's message wording/locale.
    await git(wt.repo, ['merge', '--abort'])
    return { ok: false, conflicted, message: (m.stderr || m.stdout).trim() || 'merge failed' }
  }
  return { ok: true, conflicted: false }
}

async function remove(taskId, repo) {
  const wt = worktrees.get(taskId) ?? (await rehydrate(taskId, repo))
  if (!wt) {
    // the worktree DIR is already gone (rehydrate bailed on !existsSync), but its
    // registration and the pz/<taskId> branch can still linger — prune + delete
    // so nothing leaks. Needs `repo`; without it there is nothing we can reach.
    if (!repo) return { ok: true }
    await git(repo, ['worktree', 'prune'])
    const branch = `pz/${taskId}`
    const present = await git(repo, ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`])
    const br = present.ok ? await git(repo, ['branch', '-D', branch]) : { ok: true, stdout: '', stderr: '' }
    const remains = await git(repo, ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`])
    if (!br.ok && remains.ok) return { ok: false, message: (br.stderr || br.stdout).trim().slice(0, 300) || 'worktree branch removal failed' }
    worktrees.delete(taskId)
    return { ok: true }
  }
  // Each resource is independently retryable. A previous attempt may have
  // removed the directory but failed to delete the branch (or vice versa), so
  // missing already means success instead of wedging forever on a stale Map.
  const fs = require('fs')
  const rm = fs.existsSync(wt.path)
    ? await git(wt.repo, ['worktree', 'remove', '--force', wt.path])
    : { ok: true, stdout: '', stderr: '' }
  if (!fs.existsSync(wt.path)) await git(wt.repo, ['worktree', 'prune'])
  const branchPresent = await git(wt.repo, ['show-ref', '--verify', '--quiet', `refs/heads/${wt.branch}`])
  const br = branchPresent.ok
    ? await git(wt.repo, ['branch', '-D', wt.branch])
    : { ok: true, stdout: '', stderr: '' }
  const pathRemains = fs.existsSync(wt.path)
  const branchRemains = (await git(wt.repo, ['show-ref', '--verify', '--quiet', `refs/heads/${wt.branch}`])).ok
  if (pathRemains || branchRemains) {
    // Leave the entry registered so a later retry can finish whichever half
    // remains; successful halves are recognized above and never retried.
    const bad = pathRemains && !rm.ok ? rm : br
    return { ok: false, message: (bad.stderr || bad.stdout).trim().slice(0, 300) || 'worktree remove failed' }
  }
  worktrees.delete(taskId)
  return { ok: true }
}

async function list(repo) {
  const r = await git(repo, ['worktree', 'list', '--porcelain'])
  return { ok: r.ok, raw: r.stdout }
}

function registerWorktreeHandlers(ipcMain) {
  ipcMain.handle('worktree:create', (_e, { repo, taskId }) => create(repo, taskId))
  ipcMain.handle('worktree:finalize', (_e, { taskId, message, repo }) => finalize(taskId, message, repo))
  ipcMain.handle('worktree:diff', (_e, { taskId, repo, ref }) => diff(taskId, repo, ref))
  ipcMain.handle('worktree:verify', (_e, { taskId, repo, ref }) => verify(taskId, repo, ref))
  ipcMain.handle('worktree:merge', (_e, { taskId, repo, ref }) => merge(taskId, repo, ref))
  ipcMain.handle('worktree:remove', (_e, { taskId, repo }) => remove(taskId, repo))
  ipcMain.handle('worktree:list', (_e, { repo }) => list(repo))
}

module.exports = { registerWorktreeHandlers, create, finalize, diff, verify, merge, remove, list }
