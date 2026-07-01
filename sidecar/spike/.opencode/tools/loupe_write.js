import { tool } from "@opencode-ai/plugin"

// Loupe's edit tool. Replaces the model's native file-writers: instead of writing
// to disk, it hands the edit to Loupe (via the daemon's HTTP bridge), which applies
// it through the watchable typewriter. The `await fetch` blocks until Loupe is done —
// that suspension point is what gives us interrupt-and-resume later.
export default tool({
  description:
    "Write code into the user's editor through Loupe. This is the ONLY way to create or modify a file — the human watches it typed in and can interrupt. Never use any other method to write files.",
  args: {
    file: tool.schema.string().describe("Path of the file to create or edit"),
    content: tool.schema.string().describe("The complete new contents of the file"),
  },
  async execute(args, context) {
    const port = process.env.LOUPE_BRIDGE_PORT
    if (!port) return "ERROR: Loupe bridge unavailable (LOUPE_BRIDGE_PORT unset)"
    const res = await fetch(`http://127.0.0.1:${port}/edit`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        file: args.file,
        content: args.content,
        sessionID: context.sessionID,
      }),
    })
    const out = await res.json().catch(() => ({}))
    return out.message || "applied"
  },
})
