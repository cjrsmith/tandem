// Loupe backend: Claude (via @anthropic-ai/claude-agent-sdk).
//
// A parallel implementation to the OpenCode path in daemon.mjs. It speaks the
// SAME internal protocol the daemon uses toward Neovim (session / delta / status
// / done / error events, and history / usage / compacted replies), so init.lua
// doesn't care which backend produced them. The daemon dispatches to us whenever
// a command carries backend:"claude".
//
// The loupe_* tools are exposed as an IN-PROCESS MCP server: their handlers run
// right here in the daemon and POST to the same HTTP bridge the OpenCode tools
// use — so the typewriter / ask / notify / instruct plumbing is shared verbatim.
//
// Auth: the Agent SDK needs ANTHROPIC_API_KEY (or a logged-in Claude Code) in the
// daemon's environment. If it's missing, prompts surface a friendly error.
import {
  query,
  tool,
  createSdkMcpServer,
  forkSession,
  getSessionMessages,
} from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

// POST to the daemon's local bridge (same endpoints the OpenCode tools use). The
// bridge port is published on the environment by daemon.mjs before we're loaded.
async function bridge(pathname, body) {
  const port = process.env.LOUPE_BRIDGE_PORT;
  if (!port) return {};
  const res = await fetch("http://127.0.0.1:" + port + pathname, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return res.json().catch(() => ({}));
}
const textResult = (t) => ({ content: [{ type: "text", text: t }] });

// The five Loupe tools, mirroring the tool bodies deployed for OpenCode. As MCP
// tools their model-visible names become mcp__loupe__loupe_write, etc.
const loupeServer = createSdkMcpServer({
  name: "loupe",
  version: "1.0.0",
  tools: [
    tool(
      "loupe_write",
      "Write code into the user's editor through Loupe. The ONLY way to create or modify a file; the human watches it typed in and can interrupt.",
      { file: z.string().describe("Path of the file to create or edit"), content: z.string().describe("The complete new contents of the file") },
      async (a) => textResult((await bridge("/edit", { file: a.file, content: a.content })).message || "applied"),
    ),
    tool(
      "loupe_region",
      "Replace the region of code the user has selected/marked in their editor. Return ONLY the replacement code for that region — NOT the whole file.",
      { code: z.string().describe("The replacement code for the selected region only") },
      async (a) => textResult((await bridge("/region", { code: a.code })).message || "applied"),
    ),
    tool(
      "loupe_ask",
      "Ask the user a question and wait for their answer. Use whenever you need a decision from them. Returns the user's answer.",
      { question: z.string().describe("The question to ask the user") },
      async (a) => textResult((await bridge("/ask", { question: a.question })).message || "(no answer)"),
    ),
    tool(
      "loupe_notify",
      "Briefly tell the user what you are doing or about to do (a short status line). Non-blocking. Use sparingly.",
      { message: z.string().describe("A short status message for the user") },
      async (a) => {
        await bridge("/notify", { message: a.message });
        return textResult("shown");
      },
    ),
    tool(
      "loupe_instruct",
      "Give the human ONE directive — the next step for them to do (they write the code; you guide). Issue ONE instruction, then stop and wait.",
      { instruction: z.string().describe("A short, concrete next step for the human to do") },
      async (a) => {
        await bridge("/instruct", { instruction: a.instruction });
        return textResult("shown");
      },
    ),
  ],
});

const LOUPE_TOOLS = ["loupe_write", "loupe_region", "loupe_ask", "loupe_notify", "loupe_instruct"].map(
  (t) => "mcp__loupe__" + t,
);
const WRITE_TOOLS = ["mcp__loupe__loupe_write", "mcp__loupe__loupe_region"];
const NATIVE_WRITERS = ["Write", "Edit", "MultiEdit", "NotebookEdit"];

// A short "what the AI is doing now" label from a tool call (parallels toolLabel
// in daemon.mjs; here we get MCP-prefixed names, so strip the prefix first).
function toolLabel(name, input = {}) {
  const bare = String(name).replace(/^mcp__loupe__/, "").replace(/^mcp__[^_]+__/, "");
  const base = (s) => (typeof s === "string" && s ? s.split("/").pop() : "");
  switch (bare) {
    case "Read": return "reading " + (base(input.file_path) || "a file");
    case "loupe_write": return "writing " + (base(input.file) || "a file");
    case "loupe_region": return "editing the region";
    case "Bash": return "running: " + String(input.command || "command").replace(/\s+/g, " ").slice(0, 40);
    case "Grep": return "searching" + (input.pattern ? ' "' + String(input.pattern).slice(0, 24) + '"' : "");
    case "Glob": return "finding files";
    case "loupe_ask": return "asking you something";
    case "loupe_notify": case "loupe_instruct": return "guiding you";
    default: return bare.replace(/_/g, " ");
  }
}

// Extract plain text from a stored SessionMessage's raw Anthropic message.
function messageText(raw) {
  if (!raw) return "";
  const content = raw.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b && b.type === "text" && b.text).map((b) => b.text).join("");
}

export function createClaudeBackend({ send, cwd, defaultSystem }) {
  const bySession = new Map(); // sessionId -> AbortController (for cancel)
  const cost = new Map(); // sessionId -> accumulated total_cost_usd

  async function handlePrompt(cmd) {
    const abort = new AbortController();
    const readonly = cmd.agent === "plan"; // navigator/chat: guide only, no file writes
    const disallowed = [...NATIVE_WRITERS, ...(readonly ? WRITE_TOOLS : [])];
    const allowed = [...LOUPE_TOOLS.filter((t) => !disallowed.includes(t)), "Read", "Grep", "Glob", "Bash"];

    let resume = cmd.session || undefined;
    if (cmd.fork && cmd.session) {
      // Fork: copy the session's history into a new one, then diverge (side thread).
      const forked = await forkSession(cmd.session, { dir: cwd });
      resume = forked.sessionId;
    }

    const q = query({
      prompt: cmd.text,
      options: {
        model: cmd.model && cmd.model.modelID ? cmd.model.modelID : undefined,
        resume,
        cwd,
        systemPrompt: cmd.system || defaultSystem,
        mcpServers: { loupe: loupeServer },
        allowedTools: allowed,
        disallowedTools: disallowed,
        permissionMode: "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        includePartialMessages: true,
        abortController: abort,
        env: { ...process.env },
      },
    });

    let sid = resume || null;
    let lastStatus = "";
    try {
      for await (const msg of q) {
        if (msg.type === "system" && msg.subtype === "init") {
          sid = msg.session_id;
          bySession.set(sid, abort);
          send({ tag: cmd.tag, type: "session", id: sid });
        } else if (msg.type === "stream_event") {
          const ev = msg.event;
          if (ev && ev.type === "content_block_delta" && ev.delta) {
            if (ev.delta.type === "text_delta" && ev.delta.text) {
              send({ tag: cmd.tag, type: "delta", text: ev.delta.text });
            } else if (ev.delta.type === "thinking_delta" && lastStatus !== "thinking…") {
              lastStatus = "thinking…";
              send({ type: "status", label: "thinking…" });
            }
          } else if (ev && ev.type === "content_block_start" && ev.content_block && ev.content_block.type === "tool_use") {
            const label = toolLabel(ev.content_block.name, ev.content_block.input);
            if (label && label !== lastStatus) {
              lastStatus = label;
              send({ type: "status", label });
            }
          }
        } else if (msg.type === "result") {
          if (sid) cost.set(sid, (cost.get(sid) || 0) + (msg.total_cost_usd || 0));
          if (msg.subtype !== "success" || msg.is_error) {
            send({ tag: cmd.tag, type: "error", error: msg.result || msg.subtype || "error" });
          }
          send({ tag: cmd.tag, type: "done" });
        }
      }
    } catch (e) {
      send({ tag: cmd.tag, type: "error", error: String(e && e.message ? e.message : e) });
    } finally {
      if (sid) bySession.delete(sid);
    }
  }

  function cancel(session) {
    const a = bySession.get(session);
    if (a) a.abort();
  }
  function cancelAll() {
    for (const a of bySession.values()) a.abort();
  }

  async function history(cmd) {
    try {
      const raw = await getSessionMessages(cmd.session, { dir: cwd });
      const messages = raw
        .filter((m) => m.type === "user" || m.type === "assistant")
        .map((m) => ({ role: m.type, text: messageText(m.message) }))
        .filter((m) => m.text.trim() !== "");
      send({ tag: cmd.tag, type: "history", messages });
    } catch (e) {
      send({ tag: cmd.tag, type: "error", error: String(e) });
    }
  }

  async function usage(cmd) {
    try {
      const raw = await getSessionMessages(cmd.session, { dir: cwd });
      let input = 0, output = 0, context = 0;
      for (const m of raw) {
        if (m.type !== "assistant") continue;
        const u = m.message && m.message.usage;
        if (!u) continue;
        input += u.input_tokens || 0;
        output += u.output_tokens || 0;
        context = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
      }
      send({ tag: cmd.tag, type: "usage", cost: cost.get(cmd.session) || 0, input, output, context });
    } catch (e) {
      send({ tag: cmd.tag, type: "usage", error: String(e) });
    }
  }

  async function compact(cmd) {
    // The Agent SDK runs /compact as a slash command; drive it through a resumed
    // query and wait for the turn to finish.
    try {
      const q = query({
        prompt: "/compact",
        options: { resume: cmd.session, cwd, env: { ...process.env } },
      });
      for await (const msg of q) {
        if (msg.type === "result") break;
      }
      send({ tag: cmd.tag, type: "compacted" });
    } catch (e) {
      send({ tag: cmd.tag, type: "error", error: String(e) });
    }
  }

  return { handlePrompt, cancel, cancelAll, history, usage, compact };
}
