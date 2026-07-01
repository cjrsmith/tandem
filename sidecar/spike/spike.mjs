// Standalone spike for the tool-calling backend (no Neovim involved).
//
// Proves the seam end-to-end:
//   model -> OpenCode `loupe_write` custom tool -> HTTP bridge -> (later: Neovim typewriter)
// with the native file-writers (write/edit/patch) DISABLED.
//
// Milestones it checks, in order:
//   1. the HTTP bridge starts
//   2. opencode boots and LOADS our custom tool (client.tool.ids() contains loupe_write)
//      ^ this needs no model/auth — the key de-risking check
//   3. a Driver-style prompt makes the model CALL loupe_write, which hits the bridge
//
// Run from THIS directory so opencode anchors on ./.opencode/tools:
//   cd sidecar/spike && node spike.mjs
import { createOpencode } from "@opencode-ai/sdk"
import http from "node:http"

const log = (...a) => console.log("[spike]", ...a)

// ── 1. the bridge the custom tool calls ──────────────────────────
const bridge = http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/edit") {
    let body = ""
    req.on("data", (c) => (body += c))
    req.on("end", () => {
      let edit = {}
      try { edit = JSON.parse(body || "{}") } catch {}
      log("BRIDGE /edit  file =", edit.file)
      log("  content:\n" + String(edit.content || "").split("\n").map((l) => "    | " + l).join("\n"))
      // For now: ack immediately. (Next step: forward to Neovim, await edit_done.)
      res.writeHead(200, { "content-type": "application/json" })
      res.end(JSON.stringify({ message: "applied to " + edit.file + " (spike: bridge ack)" }))
    })
  } else {
    res.writeHead(404)
    res.end()
  }
})
await new Promise((r) => bridge.listen(0, "127.0.0.1", r))
const port = bridge.address().port
process.env.LOUPE_BRIDGE_PORT = String(port)
log("bridge listening on 127.0.0.1:" + port)

// ── 2. boot opencode ─────────────────────────────────────────────
const { client, server } = await createOpencode({
  port: 0, // ephemeral port — avoid colliding with a running opencode (ServeError)
  config: { permission: { edit: "allow", bash: "allow", webfetch: "allow" } },
})
log("opencode up at", server.url)

// KEY CHECK: did opencode load our custom tool?
try {
  const ids = await client.tool.ids()
  const list = ids.data || ids
  const has = JSON.stringify(list).includes("loupe_write")
  log("tool.ids() ->", JSON.stringify(list))
  log(has ? "✅ loupe_write IS registered" : "❌ loupe_write NOT found — tool dir not picked up")
} catch (e) {
  log("tool.ids() failed:", String(e))
}

// ── 3. prompt the model to use it (needs a working model/auth) ───
async function tryPrompt() {
  const created = await client.session.create({ body: {} })
  const sid = created.data.id
  log("session", sid)

  const events = await client.event.subscribe()
  ;(async () => {
    for await (const ev of events.stream) {
      const p = ev.properties || {}
      if (ev.type === "message.part.updated" && p.part?.type === "tool") {
        log("TOOL part:", p.part.tool || p.part.name, "->", p.part.state?.status)
      } else if (ev.type === "session.idle") {
        log("session.idle (turn done)")
      } else if (ev.type === "session.error") {
        log("session.error:", JSON.stringify(p))
      }
    }
  })().catch(() => {})

  await client.session.promptAsync({
    path: { id: sid },
    body: {
      agent: "build",
      tools: { write: false, edit: false, patch: false }, // native writers OFF
      system:
        "You are a coding assistant embedded in an editor. The ONLY way you can create or modify a file is by calling the `loupe_write` tool with the file path and full content. You have no other write or edit tools. When asked to write code, call loupe_write.",
      parts: [{
        type: "text",
        text: "Create a file calc.lua containing a Lua function add(a, b) that returns a + b. Use loupe_write.",
      }],
    },
  })
  log("prompt sent; waiting for tool call / bridge hit…")
}

try {
  await tryPrompt()
} catch (e) {
  log("prompt step skipped/failed (model/auth?):", String(e))
}

// keep alive long enough to observe the tool call, then clean up
setTimeout(() => {
  log("done — shutting down")
  try { server.close() } catch {}
  try { bridge.close() } catch {}
  process.exit(0)
}, 45000)
