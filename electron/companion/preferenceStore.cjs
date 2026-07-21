'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')

const STORE_VERSION = 1
const MAX_STORE_BYTES = 16 * 1024

class CompanionPreferenceStore {
  constructor({ filePath } = {}) {
    if (typeof filePath !== 'string' || !path.isAbsolute(filePath)) {
      throw new Error('Companion preference path must be absolute.')
    }
    this.filePath = filePath
    this.value = null
  }

  load({ defaultEnabled = false } = {}) {
    if (this.value) return { ...this.value }
    let parsed = null
    let found = false
    try {
      const stat = fs.statSync(this.filePath)
      if (stat.size < 1 || stat.size > MAX_STORE_BYTES) throw new Error('Companion preferences are invalid.')
      parsed = JSON.parse(fs.readFileSync(this.filePath, 'utf8'))
      found = true
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        // A cosmetic preference must never stop the desktop app from opening.
        // Keep the unreadable file for diagnosis and fail closed in memory;
        // the next explicit toggle replaces it atomically.
        this.value = { enabled: false }
        return { ...this.value }
      }
    }
    if (found) {
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) || parsed.v !== STORE_VERSION || typeof parsed.enabled !== 'boolean') {
        this.value = { enabled: false }
        return { ...this.value }
      }
      this.value = { enabled: parsed.enabled }
      return { ...this.value }
    }
    this.value = { enabled: defaultEnabled === true }
    this.#persist()
    return { ...this.value }
  }

  setEnabled(enabled) {
    if (typeof enabled !== 'boolean') throw new Error('Companion enabled state must be true or false.')
    const previous = this.value ? { ...this.value } : null
    this.value = { enabled }
    try { this.#persist() } catch (error) {
      this.value = previous
      throw error
    }
    return { ...this.value }
  }

  #persist() {
    if (!this.value) throw new Error('Companion preferences are not initialized.')
    const encoded = JSON.stringify({ v: STORE_VERSION, enabled: this.value.enabled })
    fs.mkdirSync(path.dirname(this.filePath), { recursive: true, mode: 0o700 })
    const temporary = `${this.filePath}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`
    try {
      fs.writeFileSync(temporary, encoded, { mode: 0o600, flag: 'wx' })
      fs.renameSync(temporary, this.filePath)
      try { fs.chmodSync(this.filePath, 0o600) } catch { /* best effort on non-POSIX filesystems */ }
    } finally {
      try { fs.unlinkSync(temporary) } catch { /* renamed or never created */ }
    }
  }
}

module.exports = {
  CompanionPreferenceStore,
  MAX_STORE_BYTES,
  STORE_VERSION,
}
