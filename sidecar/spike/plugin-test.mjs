// Does config.plugin accept an ABSOLUTE PATH and register its tool, from a cwd
// that has NO .opencode/tools? If yes, that's our deployment mechanism.
import { createOpencode } from "@opencode-ai/sdk"
import path from "node:path"

const pluginPath = path.resolve(import.meta.dirname, "loupe-plugin.js")
console.log("[plugin-test] cwd =", process.cwd(), "(should NOT be the spike dir)")
console.log("[plugin-test] plugin =", pluginPath)

const { client, server } = await createOpencode({
  port: 0,
  config: { plugin: [pluginPath] },
})
console.log("[plugin-test] opencode up at", server.url)

try {
  const ids = await client.tool.ids()
  const list = ids.data || ids
  const has = JSON.stringify(list).includes("loupe_write")
  console.log("[plugin-test] tool.ids() ->", JSON.stringify(list))
  console.log("[plugin-test]", has ? "✅ loupe_write registered via plugin path" : "❌ NOT registered")
} catch (e) {
  console.log("[plugin-test] tool.ids() failed:", String(e))
}

server.close()
process.exit(0)
