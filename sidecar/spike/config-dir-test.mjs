// Can we point opencode at a LOUPE-OWNED config dir (holding tools/loupe_write.js)
// via OPENCODE_CONFIG_DIR, WITHOUT losing the user's model auth? If a prompt still
// reaches a model AND loupe_write is registered, this is the clean deployment.
import { createOpencode } from "@opencode-ai/sdk"
import http from "node:http"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const log = (...a) => console.log("[cfgdir]", ...a)

// build a throwaway loupe config dir with our tool in it
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "loupe-cfg-"))
fs.mkdirSync(path.join(dir, "tools"), { recursive: true })
fs.copyFileSync(
  path.resolve(import.meta.dirname, ".opencode/tools/loupe_write.js"),
  path.join(dir, "tools", "loupe_write.js"),
)
log("OPENCODE_CONFIG_DIR =", dir)
process.env.OPENCODE_CONFIG_DIR = dir

// bridge so a tool call has somewhere to land
const bridge = http.createServer((req, res) => {
  let b = ""; req.on("data", (c) => (b += c))
  req.on("end", () => { log("BRIDGE hit:", b.slice(0, 80)); res.writeHead(200, {"content-type":"application/json"}); res.end('{"message":"ok"}') })
})
await new Promise((r) => bridge.listen(0, "127.0.0.1", r))
process.env.LOUPE_BRIDGE_PORT = String(bridge.address().port)

const { client, server } = await createOpencode({ port: 0 })
log("opencode up at", server.url)

const ids = await client.tool.ids().then((r) => r.data || r).catch((e) => "ERR " + e)
log("loupe_write registered?", JSON.stringify(ids).includes("loupe_write"))

// does a model still respond (i.e. auth survived the config-dir override)?
try {
  const s = (await client.session.create({ body: {} })).data.id
  let gotText = false
  const events = await client.event.subscribe()
  ;(async () => { for await (const ev of events.stream) {
    const p = ev.properties || {}
    if (ev.type === "message.part.delta" && p.field === "text") gotText = true
    if (ev.type === "session.error") log("session.error:", JSON.stringify(p).slice(0, 200))
  } })().catch(() => {})
  await client.session.promptAsync({ path: { id: s }, body: { agent: "build", parts: [{ type: "text", text: "Reply with exactly: AUTH_OK" }] } })
  await new Promise((r) => setTimeout(r, 12000))
  log(gotText ? "✅ model responded — AUTH SURVIVED the config-dir override" : "❌ no model response — auth likely lost")
} catch (e) { log("prompt failed:", String(e).slice(0, 200)) }

server.close(); bridge.close()
fs.rmSync(dir, { recursive: true, force: true })
process.exit(0)
