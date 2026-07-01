import { tool } from "@opencode-ai/plugin"

// A plugin (vs a project-local tools dir) so the daemon can register loupe_write
// from an ABSOLUTE PATH in any project, via config.plugin — no repo pollution,
// no global ~/.config/opencode pollution.
export default async function LoupePlugin(ctx) {
  return {
    tool: {
      loupe_write: tool({
        description:
          "Write code into the user's editor through Loupe. The ONLY way to create or modify a file.",
        args: {
          file: tool.schema.string().describe("Path of the file to create or edit"),
          content: tool.schema.string().describe("The complete new contents of the file"),
        },
        async execute(args) {
          const port = process.env.LOUPE_BRIDGE_PORT
          if (!port) return "ERROR: Loupe bridge unavailable"
          const res = await fetch(`http://127.0.0.1:${port}/edit`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ file: args.file, content: args.content }),
          })
          const out = await res.json().catch(() => ({}))
          return out.message || "applied"
        },
      }),
    },
  }
}
