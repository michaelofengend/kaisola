// Package outside ~/Documents, where modern macOS continuously re-applies
// com.apple.provenance to Mach-O files and can race electron-builder's signer.
// Only finished archives/manifests come back into release/; the signed .app is
// verified before it leaves the unprotected staging directory.
const { spawnSync } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const yaml = require('js-yaml')

const root = path.join(__dirname, '..')
const release = path.join(root, 'release')
const args = process.argv.slice(2)
const builder = path.join(root, 'node_modules', '.bin', process.platform === 'win32' ? 'electron-builder.cmd' : 'electron-builder')

function run(command, commandArgs, options = {}) {
  const result = spawnSync(command, commandArgs, { cwd: root, stdio: 'inherit', ...options })
  if (result.error) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)
}

async function sha512(file) {
  const hash = crypto.createHash('sha512')
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk)
  return hash.digest('base64')
}

async function main() {
  if (process.platform !== 'darwin') {
    run(builder, args)
    return
  }

  const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-builder-'))
  let complete = false
  try {
    // The builder ZIP is deliberately not requested: it cannot preserve all
    // metadata covered by nested macOS signatures, so it was immediately
    // discarded and rebuilt below. Build only the DMG and create the updater
    // ZIP once, after the signed/notarized app is ready.
    run(builder, [
      ...args,
      '--mac',
      'dmg',
      '--arm64',
      '--config.dmg.writeUpdateInfo=false',
      `--config.directories.output=${stage}`,
    ])
    const app = path.join(stage, 'mac-arm64', 'Kaisola.app')
    if (!fs.existsSync(app)) throw new Error(`Packaged app is missing: ${app}`)
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', app])

    // electron-builder's archive helper can discard metadata that a nested
    // macOS code signature covers. Recreate the updater ZIP with ditto so
    // resource forks and extended attributes survive extraction.
    const dmgName = fs.readdirSync(stage).find((name) => name.endsWith('-arm64.dmg'))
    if (!dmgName) throw new Error('Packaged ARM64 DMG is missing')
    const zipName = dmgName.replace(/\.dmg$/, '-mac.zip')
    const zip = path.join(stage, zipName)
    fs.rmSync(zip, { force: true })
    // Level 3 cut this step roughly in half in a benchmark against the
    // real 869 MB app, with a measured 6% archive-size tradeoff. Level 1
    // saved only three more seconds while adding another 16 MB.
    run('/usr/bin/ditto', ['-c', '-k', '--zlibCompressionLevel', '3', '--sequesterRsrc', '--keepParent', app, zip])
    const zipInfo = {
      sha512: await sha512(zip),
      size: fs.statSync(zip).size,
    }

    // Neither blockmap was uploaded by the release workflow, so asking the
    // builder to generate one only spent time rereading the full artifact.
    // Hash the two published files directly and write the same updater schema.
    const dmg = path.join(stage, dmgName)
    const dmgInfo = {
      sha512: await sha512(dmg),
      size: fs.statSync(dmg).size,
    }
    const appPackage = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
    const manifestPath = path.join(stage, 'latest-mac.yml')
    const manifest = {
      version: appPackage.version,
      files: [
        { url: zipName, ...zipInfo },
        { url: dmgName, ...dmgInfo },
      ],
      path: zipName,
      sha512: zipInfo.sha512,
      releaseDate: new Date().toISOString(),
    }
    fs.writeFileSync(manifestPath, yaml.dump(manifest, { lineWidth: -1, noRefs: true }))

    const verification = path.join(stage, 'zip-verification')
    fs.mkdirSync(verification)
    run('/usr/bin/ditto', ['-x', '-k', zip, verification])
    run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', path.join(verification, 'Kaisola.app')])
    fs.rmSync(verification, { recursive: true, force: true })

    fs.mkdirSync(release, { recursive: true })
    for (const entry of fs.readdirSync(stage, { withFileTypes: true })) {
      if (!entry.isFile()) continue // never copy the unpacked .app into Documents
      const from = path.join(stage, entry.name)
      const to = path.join(release, entry.name)
      fs.copyFileSync(from, to)
    }
    complete = true
  } finally {
    if (complete || process.env.KAISOLA_KEEP_PACKAGE_STAGE !== '1') {
      fs.rmSync(stage, { recursive: true, force: true })
    } else {
      console.error(`Packaging stage retained for inspection: ${stage}`)
    }
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
