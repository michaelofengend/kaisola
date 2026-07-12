const { app, BrowserWindow, nativeImage } = require('electron')
const { execFileSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const root = path.join(__dirname, '..')
const svgPath = path.join(root, 'electron', 'assets', 'kaisola-icon.svg')
const pngPath = path.join(root, 'electron', 'assets', 'kaisola-icon.png')
const icnsPath = path.join(root, 'electron', 'assets', 'kaisola-icon.icns')

const copiedPngPaths = [
  path.join(root, 'public', 'kaisola-icon.png'),
  path.join(root, 'site', 'assets', 'kaisola-icon.png'),
]

function writeIcns(source) {
  if (process.platform !== 'darwin') return

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-icon-'))
  const iconsetPath = path.join(tempRoot, 'Kaisola.iconset')
  fs.mkdirSync(iconsetPath)

  try {
    for (const size of [16, 32, 128, 256, 512]) {
      for (const scale of [1, 2]) {
        const pixels = size * scale
        const suffix = scale === 2 ? '@2x' : ''
        const output = path.join(iconsetPath, `icon_${size}x${size}${suffix}.png`)
        const resized = pixels === 1024
          ? source
          : source.resize({ width: pixels, height: pixels, quality: 'best' })
        fs.writeFileSync(output, resized.toPNG())
      }
    }

    let matchesExisting = false
    if (fs.existsSync(icnsPath)) {
      const existingIconsetPath = path.join(tempRoot, 'Existing.iconset')
      try {
        execFileSync('/usr/bin/iconutil', [
          '--convert',
          'iconset',
          icnsPath,
          '--output',
          existingIconsetPath,
        ])
        const largestFile = 'icon_512x512@2x.png'
        const expected = nativeImage.createFromPath(path.join(iconsetPath, largestFile))
        const existing = nativeImage.createFromPath(path.join(existingIconsetPath, largestFile))
        matchesExisting = !expected.isEmpty()
          && !existing.isEmpty()
          && expected.getSize().width === existing.getSize().width
          && expected.getSize().height === existing.getSize().height
          && expected.toBitmap().equals(existing.toBitmap())
      } catch {
        matchesExisting = false
      }
    }

    if (!matchesExisting) {
      const nextIcnsPath = path.join(tempRoot, 'Kaisola.icns')
      execFileSync('/usr/bin/iconutil', [
        '--convert',
        'icns',
        iconsetPath,
        '--output',
        nextIcnsPath,
      ])
      fs.copyFileSync(nextIcnsPath, icnsPath)
    }
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true })
  }
}

app.disableHardwareAcceleration()
app.commandLine.appendSwitch('force-device-scale-factor', '1')

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    width: 1024,
    height: 1024,
  })

  await win.loadFile(svgPath)
  await new Promise((resolve) => setTimeout(resolve, 250))
  const capture = await win.webContents.capturePage()
  const image = nativeImage.createFromBuffer(capture.toPNG()).resize({
    width: 1024,
    height: 1024,
    quality: 'best',
  })

  fs.writeFileSync(pngPath, image.toPNG())
  for (const copyPath of copiedPngPaths) fs.copyFileSync(pngPath, copyPath)
  writeIcns(image)

  win.destroy()
  app.quit()
}).catch((error) => {
  console.error(error)
  app.exit(1)
})
