import { useEffect, useRef } from 'react'

interface Bead {
  x: number
  restX: number
  y: number
  vx: number
  color: string
  radius: number
}

const COLUMNS = 32
const ROWS = 16
const COLORS = ['#75853b', '#a3ad45', '#c3aa4f', '#bf7255', '#588074']

export function OnboardingBeads() {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    const host = canvas?.parentElement
    const context = canvas?.getContext('2d')
    if (!canvas || !host || !context) return

    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const beads: Bead[] = []
    let width = 0
    let height = 0
    let frame = 0
    let last = performance.now()
    let pointerX = Number.NaN
    let pointerY = Number.NaN

    const rebuild = () => {
      const bounds = host.getBoundingClientRect()
      width = Math.max(1, bounds.width)
      height = Math.max(1, bounds.height)
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5)
      canvas.width = Math.round(width * dpr)
      canvas.height = Math.round(height * dpr)
      canvas.style.width = `${width}px`
      canvas.style.height = `${height}px`
      context.setTransform(dpr, 0, 0, dpr, 0, 0)

      beads.length = 0
      const spacingX = Math.max(15, Math.min(21, width / 64))
      const startX = Math.max(width * 0.58, width - (COLUMNS + 2) * spacingX)
      const spacingY = height / (ROWS - 1)
      for (let column = 0; column < COLUMNS; column += 1) {
        for (let row = 0; row < ROWS; row += 1) {
          const restX = startX + column * spacingX
          beads.push({
            x: restX,
            restX,
            y: row * spacingY + (column % 2 ? spacingY * 0.3 : 0),
            vx: 0,
            color: COLORS[(column * 3 + row) % COLORS.length],
            radius: 2.6 + ((column + row * 2) % 4) * 0.32,
          })
        }
      }
    }

    const draw = () => {
      context.clearRect(0, 0, width, height)
      context.lineWidth = 0.7
      context.globalAlpha = 0.23
      for (let column = 0; column < COLUMNS; column += 1) {
        const first = beads[column * ROWS]
        if (!first) continue
        context.beginPath()
        context.moveTo(first.x, -8)
        for (let row = 0; row < ROWS; row += 1) {
          const bead = beads[column * ROWS + row]
          context.lineTo(bead.x, bead.y)
        }
        context.strokeStyle = '#697050'
        context.stroke()
      }
      context.globalAlpha = 0.78
      for (const bead of beads) {
        context.beginPath()
        context.arc(bead.x, bead.y, bead.radius, 0, Math.PI * 2)
        context.fillStyle = bead.color
        context.fill()
      }
      context.globalAlpha = 1
    }

    const tick = (now: number) => {
      const step = Math.min(2, (now - last) / 16.67)
      last = now
      const pointerActive = Number.isFinite(pointerX) && Number.isFinite(pointerY)
      const radius = 118
      for (let column = 0; column < COLUMNS; column += 1) {
        for (let row = 0; row < ROWS; row += 1) {
          const index = column * ROWS + row
          const bead = beads[index]
          const above = row > 0 ? beads[index - 1] : null
          const below = row + 1 < ROWS ? beads[index + 1] : null
          let force = (bead.restX - bead.x) * 0.038
          if (above) force += (above.x - bead.x) * 0.045
          if (below) force += (below.x - bead.x) * 0.045
          if (pointerActive) {
            const dx = bead.x - pointerX
            const dy = bead.y - pointerY
            const distance = Math.hypot(dx, dy)
            if (distance < radius) {
              const pressure = (1 - distance / radius) ** 2
              force += (dx >= 0 ? 1 : -1) * pressure * 2.8
            }
          }
          bead.vx = (bead.vx + force * step) * (0.86 ** step)
        }
      }
      for (const bead of beads) bead.x += bead.vx * step
      draw()
      frame = window.requestAnimationFrame(tick)
    }

    const onPointerMove = (event: PointerEvent) => {
      const bounds = canvas.getBoundingClientRect()
      pointerX = event.clientX - bounds.left
      pointerY = event.clientY - bounds.top
    }
    const clearPointer = (event: PointerEvent) => {
      if (event.relatedTarget) return
      pointerX = Number.NaN
      pointerY = Number.NaN
    }
    const onVisibility = () => {
      window.cancelAnimationFrame(frame)
      if (!document.hidden && !reducedMotion) {
        last = performance.now()
        frame = window.requestAnimationFrame(tick)
      }
    }

    const resize = new ResizeObserver(() => { rebuild(); draw() })
    resize.observe(host)
    rebuild()
    draw()
    window.addEventListener('pointermove', onPointerMove, { passive: true })
    window.addEventListener('pointerout', clearPointer, { passive: true })
    document.addEventListener('visibilitychange', onVisibility)
    if (!reducedMotion) frame = window.requestAnimationFrame(tick)
    return () => {
      resize.disconnect()
      window.cancelAnimationFrame(frame)
      window.removeEventListener('pointermove', onPointerMove)
      window.removeEventListener('pointerout', clearPointer)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [])

  return <canvas ref={canvasRef} className="onboarding-beads" aria-hidden="true" />
}
