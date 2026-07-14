const os = require('node:os')
const path = require('node:path')

function resolveUserPath(input, cwd) {
  if (typeof input !== 'string' || !input || input.length > 4096 || input.includes('\0')) return null
  const raw = input.trim().replace(/^(?:["'`])|(?:["'`])$/g, '')
  if (!raw) return null
  const expanded = raw.replace(/^~(?=\/|$)/, os.homedir())
  const base = typeof cwd === 'string' && cwd ? cwd : os.homedir()
  return path.isAbsolute(expanded) ? path.normalize(expanded) : path.resolve(base, expanded)
}

module.exports = { resolveUserPath }
