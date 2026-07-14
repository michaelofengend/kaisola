export interface TerminalFileLinkCandidate {
  text: string
  path: string
  line?: number
  column?: number
  start: number
  end: number
}

const PATH_WITH_PREFIX = /(?:^|[\s([{<"'`])((?:~\/|\/|\.\.?\/)[^\s<>"'`]+|(?:[A-Za-z0-9_@.+%~-]+\/)+[^\s<>"'`]+)/g
const BARE_FILE = /(?:^|[\s([{<"'`])([A-Za-z0-9_@+%~-]+\.(?:[cm]?[jt]sx?|py|rb|rs|go|java|kt|swift|c|cc|cpp|h|hpp|css|scss|less|html?|mdx?|txt|jsonl?|ya?ml|toml|ini|sh|zsh|fish|sql|tex|bib|csv|tsv|pdf|png|jpe?g|gif|webp|svg|mov|mp4|m4v|webm)(?::\d+(?::\d+)?)?)/gi
const WEB_SCHEME = /^[a-z][a-z0-9+.-]*:\/\//i
const TRAILING_PROSE = /[),.;!?\]}]+$/

function parseCandidate(raw: string, start: number): TerminalFileLinkCandidate | null {
  let text = raw.replace(TRAILING_PROSE, '')
  if (!text || WEB_SCHEME.test(text)) return null

  let line: number | undefined
  let column: number | undefined
  const hash = text.match(/#L(\d+)(?::(\d+))?$/i)
  const suffix = hash ? null : text.match(/:(\d+)(?::(\d+))?$/)
  const location = hash ?? suffix
  if (location) {
    line = Number(location[1])
    column = location[2] ? Number(location[2]) : undefined
    text = text.slice(0, -location[0].length)
  }
  if (!text || text === '/' || text === './' || text === '../' || text === '~/') return null

  const display = raw.slice(0, text.length + (location?.[0].length ?? 0))
  return {
    text: display,
    path: text,
    ...(line && line > 0 ? { line } : {}),
    ...(column && column > 0 ? { column } : {}),
    start,
    end: start + display.length,
  }
}

/**
 * Find filesystem-looking tokens in one rendered terminal row. Resolution and
 * existence checks happen in Electron main when the user clicks; this parser
 * only decides which text receives a link affordance.
 */
export function terminalFileLinkCandidates(value: string): TerminalFileLinkCandidate[] {
  const found: TerminalFileLinkCandidate[] = []
  const seen = new Set<string>()
  for (const pattern of [PATH_WITH_PREFIX, BARE_FILE]) {
    pattern.lastIndex = 0
    let match: RegExpExecArray | null
    while ((match = pattern.exec(value))) {
      const raw = match[1]
      const start = match.index + match[0].lastIndexOf(raw)
      const candidate = parseCandidate(raw, start)
      if (!candidate) continue
      const key = `${candidate.start}:${candidate.end}`
      if (seen.has(key)) continue
      seen.add(key)
      found.push(candidate)
    }
  }
  return found.sort((a, b) => a.start - b.start || b.end - a.end)
}
