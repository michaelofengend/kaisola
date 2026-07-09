// Proves the session/new "Invalid params" root cause: ACP agents zod-reject
// an mcpServers entry whose headers is an OBJECT map; the spec wants
// HttpHeader[] ({name,value} pairs). Speaks raw line-delimited JSON-RPC to
// the real agent binaries, old shape vs new shape vs none.
import { spawn } from 'node:child_process'
import http from 'node:http'

const CWD = '/Users/michaelofengenden/Documents/Kaisola'
const AGENTS = [
  { id: 'claude', cmd: 'npx', args: ['-y', '@zed-industries/claude-code-acp'] },
  { id: 'codex', cmd: 'npx', args: ['-y', '@zed-industries/codex-acp'] },
]

// a stand-in MCP endpoint so agents that eagerly dial the URL get a socket
const mcpSrv = http.createServer((req, res) => {
  let body = ''
  req.on('data', (d) => (body += d))
  req.on('end', () => {
    let id = null
    try { id = JSON.parse(body).id ?? null } catch { /* notification */ }
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify({ jsonrpc: '2.0', id, result: { capabilities: {}, protocolVersion: '2025-03-26', serverInfo: { name: 'probe', version: '0' } } }))
  })
})
await new Promise((r) => mcpSrv.listen(0, '127.0.0.1', r))
const url = `http://127.0.0.1:${mcpSrv.address().port}/`

const SHAPES = {
  oldObj: [{ type: 'http', name: 'kaisola', url, headers: { Authorization: 'Bearer probe' } }],
  newArr: [{ type: 'http', name: 'kaisola', url, headers: [{ name: 'Authorization', value: 'Bearer probe' }] }],
  none: [],
}

function once(agent, shapeName, mcpServers) {
  return new Promise((resolve) => {
    const env = { ...process.env }
    delete env.CLAUDECODE
    delete env.CLAUDE_CODE_ENTRYPOINT
    const p = spawn(agent.cmd, agent.args, { cwd: CWD, env, stdio: ['pipe', 'pipe', 'pipe'] })
    let buf = ''
    let nextId = 1
    const pending = new Map()
    const finish = (out) => { try { p.kill() } catch {} ; clearTimeout(timer); resolve({ agent: agent.id, shape: shapeName, ...out }) }
    const timer = setTimeout(() => finish({ outcome: 'timeout' }), 120_000)
    const send = (method, params) => new Promise((res2, rej2) => {
      const id = nextId++
      pending.set(id, { res2, rej2 })
      p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
    })
    p.stdout.on('data', (d) => {
      buf += d.toString()
      let nl
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl).trim()
        buf = buf.slice(nl + 1)
        if (!line) continue
        let m
        try { m = JSON.parse(line) } catch { continue }
        if (m.id != null && (m.result !== undefined || m.error !== undefined)) {
          const pr = pending.get(m.id)
          if (pr) { pending.delete(m.id); m.error ? pr.rej2(m.error) : pr.res2(m.result) }
        } else if (m.id != null && m.method) {
          // agent → client request (permissions etc.) — refuse politely
          p.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'probe' } }) + '\n')
        }
      }
    })
    p.on('error', (e) => finish({ outcome: 'spawn-error', detail: e.message }))
    p.on('exit', (c) => finish({ outcome: `exited(${c})` }))
    ;(async () => {
      try {
        await send('initialize', { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: true } })
        try {
          const s = await send('session/new', { cwd: CWD, mcpServers })
          finish({ outcome: 'SESSION_OK', sessionId: s && s.sessionId ? 'yes' : 'missing' })
        } catch (err) {
          finish({ outcome: 'SESSION_ERR', code: err.code, message: err.message, data: JSON.stringify(err.data || null).slice(0, 300) })
        }
      } catch (err) {
        finish({ outcome: 'INIT_ERR', code: err.code, message: err.message })
      }
    })()
  })
}

for (const agent of AGENTS) {
  for (const [name, servers] of Object.entries(SHAPES)) {
    const r = await once(agent, name, servers)
    console.log(JSON.stringify(r))
  }
}
mcpSrv.close()
