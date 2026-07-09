// The Kaisola MCP server — ONE tool surface every connected agent shares.
// From the Traycer deep-dive architecture: instead of a proprietary
// agent-to-agent bus, the IDE exposes its state over MCP and hands the SAME
// server to every agent — the Claude terminal gets it via `--mcp-config`,
// ACP agents (Codex, Gemini, OpenCode…) get it in `session/new` mcpServers.
//
// Transport: Streamable HTTP (spec 2025-06-18), plain-JSON responses, bound to
// 127.0.0.1 on an ephemeral port. Hardened: per-launch bearer token + Host
// allowlist (DNS-rebinding guard). Hand-rolled on node:http — the request/
// response subset we need (initialize / tools/list / tools/call / ping) is
// small and dependency-free.
//
// Read tools reach the renderer's PERSISTED store (throttled ~800ms behind
// live state — fine for research reads). Write tools touch ONLY the agent-task
// ledger (coordination), never project state: research mutations stay behind
// the human proposal gate.
const http = require('node:http')
const crypto = require('node:crypto')
const path = require('node:path')
const fs = require('node:fs')
const { app } = require('electron')
const { dbGet } = require('./dbHandler.cjs')
const ledger = require('./ledgerHandler.cjs')

const PROTOCOL = '2025-06-18'
let server = null
let port = 0
let token = ''

/** The renderer's persisted zustand state (active project lives flat). */
function storeState() {
  try {
    const raw = dbGet('kaisola-store')
    if (!raw) return null
    const parsed = JSON.parse(raw)
    return parsed && parsed.state ? parsed.state : parsed
  } catch {
    return null
  }
}

const snip = (s, n) => (typeof s === 'string' && s.length > n ? `${s.slice(0, n)}…` : s)

// ── tools ───────────────────────────────────────────────────────────────────
const TOOLS = [
  {
    name: 'project_overview',
    description: 'The active Kaisola project: name, research question, workspace path, campaign, and counts of corpus sources, hypotheses, claims, experiments and runs. Call this first to orient.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    run: () => {
      const s = storeState()
      if (!s) return { error: 'No project state available yet.' }
      const p = s.project || {}
      return {
        name: p.name || null,
        question: p.question || null,
        workspacePath: s.workspacePath || null,
        stage: s.stage || null,
        campaign: p.campaign ? { title: p.campaign.title, status: p.campaign.status } : null,
        counts: {
          corpus: (p.corpus || []).length,
          hypotheses: (p.hypotheses || []).length,
          claims: ((p.claimGraph || {}).nodes || []).length,
          experiments: (p.experiments || []).length,
          runs: (p.runs || []).length,
          proposals: (p.proposals || []).length,
        },
      }
    },
  },
  {
    name: 'corpus_search',
    description: 'Search the project corpus (papers, repos, datasets, notes) by title/abstract substring. Empty query lists the most recent items.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: 'Case-insensitive substring; empty = list all' },
        limit: { type: 'number', description: 'Max items (default 10)' },
      },
      additionalProperties: false,
    },
    run: ({ query, limit } = {}) => {
      const s = storeState()
      const corpus = ((s && s.project) || {}).corpus || []
      const q = String(query || '').toLowerCase()
      const hits = corpus
        .filter((c) => !q || `${c.title || ''} ${c.abstract || ''} ${c.summary || ''}`.toLowerCase().includes(q))
        .slice(0, Math.min(Number(limit) || 10, 50))
        .map((c) => ({ id: c.id, kind: c.kind, title: c.title, year: c.year, abstract: snip(c.abstract, 500) }))
      return { total: corpus.length, matched: hits.length, items: hits }
    },
  },
  {
    name: 'hypotheses_list',
    description: 'List the project hypotheses (id, title, claim, status).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    run: () => {
      const s = storeState()
      const hyps = ((s && s.project) || {}).hypotheses || []
      return { items: hyps.slice(0, 50).map((h) => ({ id: h.id, title: h.title, claim: snip(h.claim, 400), status: h.status })) }
    },
  },
  {
    name: 'runs_list',
    description: 'List experiment runs (id, label, status, summary) — the lab-notebook trail.',
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'number', description: 'Max items (default 15)' } },
      additionalProperties: false,
    },
    run: ({ limit } = {}) => {
      const s = storeState()
      const runs = ((s && s.project) || {}).runs || []
      return { items: runs.slice(-Math.min(Number(limit) || 15, 50)).map((r) => ({ id: r.id, label: r.label, status: r.status, summary: snip(r.summary, 400) })) }
    },
  },
  {
    name: 'agent_tasks_list',
    description: 'The shared agent-task ledger — how agents coordinate in Kaisola. Lists tasks other agents (or the human) posted: check for open work addressed to you, or read results teammates posted.',
    inputSchema: {
      type: 'object',
      properties: { status: { type: 'string', description: 'Filter: open | claimed | in_progress | blocked | review | done | rejected' } },
      additionalProperties: false,
    },
    run: ({ status } = {}) => {
      const s = storeState()
      return { tasks: ledger.listTasks({ project: (s && s.workspacePath) || undefined, status }) }
    },
  },
  {
    name: 'agent_task_post',
    description: 'Post a task or a result to the shared agent ledger — the sanctioned way to hand work to another agent or leave a finding for the team. Writes ONLY coordination state (never project files or research state) and is visible to the human in the activity feed. Set `owner` to address a specific agent (e.g. "codex", "claude").',
    inputSchema: {
      type: 'object',
      properties: {
        title: { type: 'string', description: 'Short imperative title' },
        detail: { type: 'string', description: 'What needs doing / what was found, with references' },
        owner: { type: 'string', description: 'Agent this is addressed to (optional)' },
        from: { type: 'string', description: 'Your agent name' },
      },
      required: ['title'],
      additionalProperties: false,
    },
    run: ({ title, detail, owner, from } = {}) => {
      const s = storeState()
      return ledger.postTask({ project: (s && s.workspacePath) || undefined, title, detail, owner, createdBy: from })
    },
  },
  {
    name: 'agent_task_update',
    description: 'Update a ledger task: claim it (status=claimed, owner=you), report progress (in_progress/blocked), or finish it (done + result). Ledger-only — never mutates project state.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'string' },
        status: { type: 'string', description: 'open | claimed | in_progress | blocked | review | done | rejected' },
        owner: { type: 'string', description: 'Your agent name when claiming' },
        result: { type: 'string', description: 'Outcome summary when finishing' },
      },
      required: ['id'],
      additionalProperties: false,
    },
    run: (args = {}) => ledger.updateTask(args),
  },
]

// ── JSON-RPC over Streamable HTTP ───────────────────────────────────────────
function rpcResult(id, result) {
  return { jsonrpc: '2.0', id, result }
}
function rpcError(id, code, message) {
  return { jsonrpc: '2.0', id, error: { code, message } }
}

function handleRpc(msg) {
  const { id, method, params } = msg
  if (method === 'initialize') {
    return rpcResult(id, {
      protocolVersion: PROTOCOL,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: 'kaisola', title: 'Kaisola Research IDE', version: app.getVersion() },
      instructions: 'Kaisola project state (read) + the shared agent-task ledger (coordinate with other agents). Research state is human-gated: post findings as ledger tasks, never assume writes.',
    })
  }
  if (method === 'ping') return rpcResult(id, {})
  if (method === 'tools/list') {
    return rpcResult(id, { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) })
  }
  if (method === 'tools/call') {
    const tool = TOOLS.find((t) => t.name === (params && params.name))
    if (!tool) return rpcError(id, -32602, `Unknown tool: ${params && params.name}`)
    try {
      const out = tool.run((params && params.arguments) || {})
      return rpcResult(id, {
        content: [{ type: 'text', text: JSON.stringify(out, null, 1).slice(0, 100_000) }],
        structuredContent: out,
        isError: !!(out && out.ok === false),
      })
    } catch (err) {
      return rpcResult(id, { content: [{ type: 'text', text: `Tool failed: ${String((err && err.message) || err)}` }], isError: true })
    }
  }
  if (typeof method === 'string' && method.startsWith('notifications/')) return null // 202, no body
  return rpcError(id, -32601, `Method not implemented: ${method}`)
}

function startMcpServer() {
  if (server) return
  token = crypto.randomBytes(24).toString('hex')
  server = http.createServer((req, res) => {
    // DNS-rebinding guard: loopback host only, and our bearer or nothing
    const host = String(req.headers.host || '')
    if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) { res.writeHead(403); return res.end() }
    if (req.headers.authorization !== `Bearer ${token}`) { res.writeHead(401); return res.end() }
    if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end() }
    let body = ''
    req.on('data', (c) => { body += c; if (body.length > 1_000_000) req.destroy() })
    req.on('end', () => {
      let msg
      try { msg = JSON.parse(body) } catch { res.writeHead(400); return res.end() }
      // batches are removed in 2025-06-18; handle single messages
      const reply = handleRpc(msg)
      if (!reply) { res.writeHead(202); return res.end() }
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify(reply))
    })
  })
  server.listen(0, '127.0.0.1', () => {
    port = server.address().port
    // the Claude terminal picks the server up via `claude --mcp-config <this file>`
    try {
      fs.writeFileSync(configPath(), JSON.stringify({
        mcpServers: { kaisola: { type: 'http', url: `http://127.0.0.1:${port}/`, headers: { Authorization: `Bearer ${token}` } } },
      }, null, 2))
    } catch { /* claude just boots without the kaisola tools */ }
  })
  server.unref?.()
}

function configPath() {
  return path.join(app.getPath('userData'), 'kaisola-mcp.json')
}

/** The ACP `session/new` mcpServers entry (agents advertising http support). */
function mcpHttpEntry() {
  if (!port) return null
  return { type: 'http', name: 'kaisola', url: `http://127.0.0.1:${port}/`, headers: { Authorization: `Bearer ${token}` } }
}

function registerMcpHandlers(ipcMain) {
  startMcpServer()
  ipcMain.handle('mcp:info', () => ({
    ok: !!port,
    url: port ? `http://127.0.0.1:${port}/` : null,
    // only offer the config file once it's actually on disk — a boot line
    // pointing at a missing file would make claude error at launch
    configPath: fs.existsSync(configPath()) ? configPath() : null,
  }))
}

function disposeMcp() {
  try { server?.close() } catch { /* going down anyway */ }
  server = null
}

module.exports = { registerMcpHandlers, disposeMcp, mcpHttpEntry }
