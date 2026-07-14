const { spawnSync } = require('node:child_process')
const path = require('node:path')

if (process.env.KAISOLA_SKIP_NATIVE_REBUILD === '1') {
  // electron-builder performs the same architecture-specific rebuild while
  // packaging. The release workflow skips this earlier duplicate pass.
  console.log('Skipping native rebuild; electron-builder will run it during packaging.')
  process.exit(0)
}

const executable = path.join(
  __dirname,
  '..',
  'node_modules',
  '.bin',
  process.platform === 'win32' ? 'electron-rebuild.cmd' : 'electron-rebuild',
)
const result = spawnSync(executable, ['-f', '-w', 'node-pty', '-w', 'better-sqlite3'], {
  stdio: 'inherit',
})

// Preserve the existing install behavior: a missing local toolchain should
// not make npm install unusable, but `npm run rebuild` remains available.
if (result.error || result.status !== 0) {
  console.warn('Native rebuild skipped — run: npm run rebuild')
}
