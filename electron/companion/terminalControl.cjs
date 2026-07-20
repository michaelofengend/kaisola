'use strict'

const crypto = require('node:crypto')

const DEFAULT_LEASE_TTL_MS = 30_000
const MAX_TERMINAL_INPUT_BYTES = 16 * 1024
const MIN_COLS = 20
const MAX_COLS = 400
const MIN_ROWS = 5
const MAX_ROWS = 200

function result(ok, status, message, payload) {
  return { ok, status, message, ...(payload ? { payload } : {}) }
}

function terminalKey(projectId, terminalId) {
  return `${projectId}\0${terminalId}`
}

/** A companion lease never changes PTY ownership. It is an additional,
 * short-lived authorization checked before each main-owned broker operation. */
class CompanionTerminalControl {
  constructor({
    terminalAdapter,
    ttlMs = DEFAULT_LEASE_TTL_MS,
    now = Date.now,
    randomUUID = crypto.randomUUID,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
  } = {}) {
    if (!terminalAdapter?.available || !terminalAdapter?.write || !terminalAdapter?.resize || !terminalAdapter?.interrupt) {
      throw new Error('terminal control adapter is required')
    }
    if (!Number.isSafeInteger(ttlMs) || ttlMs < 1_000 || ttlMs > 5 * 60_000) throw new Error('terminal lease ttl is invalid')
    this.terminalAdapter = terminalAdapter
    this.ttlMs = ttlMs
    this.now = now
    this.randomUUID = randomUUID
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.leases = new Map()
    this.restores = new Map()
  }

  handlers() {
    return {
      'terminal.acquire-control': (context) => this.acquire(context),
      'terminal.renew-control': (context) => this.renew(context),
      'terminal.write': (context) => this.write(context),
      'terminal.resize': (context) => this.resize(context),
      'terminal.interrupt': (context) => this.interrupt(context),
      'terminal.release-control': (context) => this.release(context),
    }
  }

  async acquire({ device, command, session }) {
    const identity = this.#identity(device, command, session)
    if (!identity) return result(false, 'rejected', 'Terminal control request is invalid.')
    const key = terminalKey(command.projectId, command.targetId)
    await this.#expireIfNeeded(key)
    await this.#waitForRestore(key)
    const current = this.leases.get(key)
    if (current && !this.#sameHolder(current, identity)) {
      return result(false, 'rejected', 'Terminal is already controlled from another device.')
    }
    const available = await this.terminalAdapter.available({ id: command.targetId, projectId: command.projectId })
    if (!available?.ok) return result(false, available?.status ?? 'unavailable', available?.message ?? 'Terminal is unavailable.')
    const lease = current ?? {
      key,
      leaseId: `lease-${this.randomUUID()}`,
      deviceId: identity.deviceId,
      connectionId: identity.connectionId,
      session,
      projectId: command.projectId,
      terminalId: command.targetId,
      originalGeometry: this.#geometry(available.geometry),
      timer: null,
    }
    this.#arm(lease)
    this.leases.set(key, lease)
    return result(true, 'applied', 'Terminal control enabled.', this.#payload(lease))
  }

  async renew(context) {
    const lease = await this.#requireLease(context)
    if (lease.error) return lease.error
    this.#arm(lease)
    return result(true, 'applied', 'Terminal control renewed.', this.#payload(lease))
  }

  async write(context) {
    const lease = await this.#requireLease(context)
    if (lease.error) return lease.error
    const data = context.command.payload?.data
    const bytes = typeof data === 'string' ? Buffer.byteLength(data, 'utf8') : 0
    if (!bytes || bytes > MAX_TERMINAL_INPUT_BYTES) {
      return result(false, 'rejected', `Terminal input must be between 1 and ${MAX_TERMINAL_INPUT_BYTES} bytes.`)
    }
    const applied = await this.terminalAdapter.write({
      id: lease.terminalId,
      projectId: lease.projectId,
      data,
    })
    if (!applied?.ok) return result(false, applied?.status ?? 'unavailable', applied?.message ?? 'Terminal input was not applied.')
    return result(true, 'applied', 'Terminal input applied.')
  }

  async resize(context) {
    const lease = await this.#requireLease(context)
    if (lease.error) return lease.error
    if (!lease.originalGeometry) {
      return result(false, 'unavailable', 'Terminal resize is unavailable until the desktop session reconnects.')
    }
    const cols = context.command.payload?.cols
    const rows = context.command.payload?.rows
    if (!Number.isSafeInteger(cols) || cols < MIN_COLS || cols > MAX_COLS
      || !Number.isSafeInteger(rows) || rows < MIN_ROWS || rows > MAX_ROWS) {
      return result(false, 'rejected', 'Terminal size is outside the supported range.')
    }
    const applied = await this.terminalAdapter.resize({
      id: lease.terminalId,
      projectId: lease.projectId,
      cols,
      rows,
    })
    if (!applied?.ok) return result(false, applied?.status ?? 'unavailable', applied?.message ?? 'Terminal resize was not applied.')
    return result(true, 'applied', 'Terminal size applied.')
  }

  async interrupt(context) {
    const lease = await this.#requireLease(context)
    if (lease.error) return lease.error
    const applied = await this.terminalAdapter.interrupt({ id: lease.terminalId, projectId: lease.projectId })
    if (!applied?.ok) return result(false, applied?.status ?? 'unavailable', applied?.message ?? 'Interrupt was not applied.')
    return result(true, 'applied', 'Interrupt sent.')
  }

  async release(context) {
    const lease = await this.#requireLease(context)
    if (lease.error) return lease.error
    await this.#drop(lease.key)
    return result(true, 'applied', 'Terminal control released.')
  }

  async releaseSession(session) {
    const drops = []
    for (const [key, lease] of this.leases) {
      if (lease.session !== session) continue
      drops.push(this.#drop(key))
    }
    await Promise.allSettled(drops)
    return drops.length
  }

  async dispose() {
    await Promise.allSettled([...this.leases.keys()].map((key) => this.#drop(key)))
    await Promise.allSettled([...this.restores.values()])
  }

  stats() {
    for (const key of [...this.leases.keys()]) void this.#expireIfNeeded(key)
    return { activeLeases: this.leases.size, restoringGeometry: this.restores.size, ttlMs: this.ttlMs }
  }

  #identity(device, command, session) {
    if (!session?.connectionId || !device?.deviceId || !command?.projectId || !command?.targetId) return null
    return { deviceId: device.deviceId, connectionId: session.connectionId }
  }

  #sameHolder(lease, identity) {
    return lease.deviceId === identity.deviceId && lease.connectionId === identity.connectionId
  }

  async #requireLease({ device, command, session }) {
    const identity = this.#identity(device, command, session)
    if (!identity) return { error: result(false, 'rejected', 'Terminal control request is invalid.') }
    const key = terminalKey(command.projectId, command.targetId)
    await this.#expireIfNeeded(key)
    const lease = this.leases.get(key)
    const leaseId = command.payload?.leaseId
    if (!lease || typeof leaseId !== 'string' || lease.leaseId !== leaseId || !this.#sameHolder(lease, identity)) {
      return { error: result(false, 'stale', 'Terminal control lease is missing or expired.') }
    }
    return lease
  }

  #payload(lease) {
    return {
      leaseId: lease.leaseId,
      expiresAt: lease.expiresAt,
      renewAfterMs: Math.floor(this.ttlMs / 3),
      resizeEnabled: !!lease.originalGeometry,
    }
  }

  #arm(lease) {
    if (lease.timer) this.clearTimer(lease.timer)
    lease.expiresAt = this.now() + this.ttlMs
    lease.timer = this.setTimer(() => {
      if (this.leases.get(lease.key) === lease && lease.expiresAt <= this.now()) void this.#drop(lease.key)
    }, this.ttlMs + 5)
    lease.timer?.unref?.()
  }

  async #expireIfNeeded(key) {
    const lease = this.leases.get(key)
    if (lease && lease.expiresAt <= this.now()) await this.#drop(key)
  }

  async #drop(key) {
    const lease = this.leases.get(key)
    if (!lease) {
      await this.#waitForRestore(key)
      return false
    }
    if (lease.timer) this.clearTimer(lease.timer)
    this.leases.delete(key)
    if (lease.originalGeometry) {
      const restore = Promise.resolve().then(() => this.terminalAdapter.resize({
        id: lease.terminalId,
        projectId: lease.projectId,
        ...lease.originalGeometry,
      })).catch(() => null).finally(() => {
        if (this.restores.get(key) === restore) this.restores.delete(key)
      })
      this.restores.set(key, restore)
      await restore
    }
    return true
  }

  async #waitForRestore(key) {
    const restore = this.restores.get(key)
    if (restore) await restore
  }

  #geometry(value) {
    const cols = value?.cols
    const rows = value?.rows
    return Number.isSafeInteger(cols) && cols > 0 && Number.isSafeInteger(rows) && rows > 0
      ? { cols, rows }
      : null
  }
}

module.exports = {
  CompanionTerminalControl,
  DEFAULT_LEASE_TTL_MS,
  MAX_TERMINAL_INPUT_BYTES,
}
