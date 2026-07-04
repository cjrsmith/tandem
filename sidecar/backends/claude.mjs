// Tandem backend: Claude (via @anthropic-ai/claude-agent-sdk).
//
// A parallel implementation to the OpenCode path in daemon.mjs. It speaks the
// SAME internal protocol the daemon uses toward Neovim (session / delta / status
// / done / error events, and history / usage / compacted replies), so init.lua
// doesn't care which backend produced them. The daemon dispatches to us whenever
// a command carries backend:"claude".
//
// The tandem_* tools are exposed as an IN-PROCESS MCP server: their handlers run
// right here in the daemon and POST to the same HTTP bridge the OpenCode tools
// use — so the typewriter / ask / notify / instruct plumbing is shared verbatim.
//
// Auth: the Agent SDK spawns the `claude` binary, which uses the user's Claude Code
// login (a Pro/Max subscription works) — no API key needed in the daemon's environment.
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
  const port = process.env.TANDEM_BRIDGE_PORT;
  if (!port) return {};
  const res = await fetch("http://127.0.0.1:" + port + pathname, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return res.json().catch(() => ({}));
}
const textResult = (t) => ({ content: [{ type: "text", text: t }] });

// The five Tandem tools, mirroring the tool bodies deployed for OpenCode. As MCP
// tools their model-visible names become mcp__tandem__tandem_write, etc.
const tandemServer = createSdkMcpServer({
  name: "tandem",
  version: "1.0.0",
  tools: [
    tool(
      "tandem_write",
      "Write code into the user's editor through Tandem. The ONLY way to create or modify a file; the human watches it typed in and can interrupt.",
      { file: z.string().describe("Path of the file to create or edit"), content: z.string().describe("The complete new contents of the file") },
      async (a) => textResult((await bridge("/edit", { file: a.file, content: a.content })).message || "applied"),
    ),
    tool(
      "tandem_region",
      "Replace the region of code the user has selected/marked in their editor. Return ONLY the replacement code for that region — NOT the whole file.",
      { code: z.string().describe("The replacement code for the selected region only") },
      async (a) => textResult((await bridge("/region", { code: a.code })).message || "applied"),
    ),
    tool(
      "tandem_ask",
      "Ask the user a question and wait for their answer. Use whenever you need a decision from them. Returns the user's answer.",
      { question: z.string().describe("The question to ask the user") },
      async (a) => textResult((await bridge("/ask", { question: a.question })).message || "(no answer)"),
    ),
    tool(
      "tandem_notify",
      "Briefly tell the user what you are doing or about to do (a short status line). Non-blocking. Use sparingly.",
      { message: z.string().describe("A short status message for the user") },
      async (a) => {
        await bridge("/notify", { message: a.message });
        return textResult("shown");
      },
    ),
    tool(
      "tandem_instruct",
      "Give the human ONE directive — the next step for them to do (they write the code; you guide). Issue ONE instruction, then stop and wait.",
      { instruction: z.string().describe("A short, concrete next step for the human to do") },
      async (a) => {
        await bridge("/instruct", { instruction: a.instruction });
        return textResult("shown");
      },
    ),
    tool(
      "tandem_journal",
      "Curate this workpackage's JOURNAL — a concise, always-current brief (goal, current state, key decisions, approach) injected into every session here. Pass the COMPLETE updated markdown; it replaces the old one. Keep it tight; update as decisions are made.",
      { content: z.string().describe("The complete updated journal markdown (a concise brief)") },
      async (a) => {
        await bridge("/journal", { content: a.content });
        return textResult("journal updated");
      },
    ),
    tool(
      "tandem_backlog",
      "Update this workpackage's BACKLOG: add new concrete tasks and/or mark finished ones done. Does NOT rewrite the list, so the human's ordering is preserved.",
      {
        add: z.array(z.string()).optional().describe("New tasks to append (highest priority first)"),
        complete: z.array(z.string()).optional().describe("Texts of existing tasks to mark done"),
      },
      async (a) => {
        await bridge("/backlog", { add: a.add || [], complete: a.complete || [] });
        return textResult("backlog updated");
      },
    ),
  ],
});

const TANDEM_TOOLS = [
  "tandem_write",
  "tandem_region",
  "tandem_ask",
  "tandem_notify",
  "tandem_instruct",
  "tandem_journal",
  "tandem_backlog",
].map((t) => "mcp__tandem__" + t);
const WRITE_TOOLS = ["mcp__tandem__tandem_write", "mcp__tandem__tandem_region"];
const NATIVE_WRITERS = ["Write", "Edit", "MultiEdit", "NotebookEdit"];
// Auto-allowed (read-only, harmless) native tools — no permission prompt.
const SAFE_TOOLS = new Set(["Read", "Grep", "Glob", "NotebookRead", "TodoWrite"]);

// Reasoning effort → Claude thinking budget (same effort labels the OpenCode side uses).
// undefined → omit, let the SDK/model decide.
function effortToThinking(effort) {
  switch (effort) {
    case "minimal": return { type: "disabled" };
    case "low": return { type: "enabled", budgetTokens: 4000 };
    case "medium": return { type: "enabled", budgetTokens: 12000 };
    case "high": return { type: "enabled", budgetTokens: 32000 };
    default: return undefined;
  }
}

// Claude models offered in the picker. All support reasoning (thinking). Uses the
// user's Claude Code login (no API key) — the SDK spawns the claude binary.
function listModels() {
  return [
    { backend: "claude", providerID: "anthropic", modelID: "claude-opus-4-8", label: "Claude · Opus 4.8", reasoning: true },
    { backend: "claude", providerID: "anthropic", modelID: "claude-sonnet-4-6", label: "Claude · Sonnet 4.6", reasoning: true },
    { backend: "claude", providerID: "anthropic", modelID: "claude-haiku-4-5-20251001", label: "Claude · Haiku 4.5", reasoning: true },
  ];
}

// A short "what the AI is doing now" label from a tool call (parallels toolLabel
// in daemon.mjs; here we get MCP-prefixed names, so strip the prefix first).
function toolLabel(name, input = {}) {
  const bare = String(name).replace(/^mcp__tandem__/, "").replace(/^mcp__[^_]+__/, "");
  const base = (s) => (typeof s === "string" && s ? s.split("/").pop() : "");
  switch (bare) {
    case "Read": return "reading " + (base(input.file_path) || "a file");
    case "tandem_write": return "writing " + (base(input.file) || "a file");
    case "tandem_region": return "editing the region";
    case "Bash": return "running: " + String(input.command || "command").replace(/\s+/g, " ").slice(0, 40);
    case "Grep": return "searching" + (input.pattern ? ' "' + String(input.pattern).slice(0, 24) + '"' : "");
    case "Glob": return "finding files";
    case "tandem_ask": return "asking you something";
    case "tandem_notify": case "tandem_instruct": return "guiding you";
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

export function createClaudeBackend({ send, cwd, defaultSystem, requestPermission }) {
  const bySession = new Map(); // sessionId -> AbortController (for cancel)
  const cost = new Map(); // sessionId -> accumulated total_cost_usd
  const alwaysAllow = new Set(); // tools the user chose "always" for (this daemon run)

  // Gate side-effecting native tools (bash, webfetch, …) through the editor. Tandem's
  // own tools + read-only tools are auto-allowed; everything else asks once/always/reject.
  async function canUseTool(toolName, input) {
    if (toolName.startsWith("mcp__tandem__") || SAFE_TOOLS.has(toolName) || alwaysAllow.has(toolName)) {
      return { behavior: "allow", updatedInput: input };
    }
    if (!requestPermission) {
      return { behavior: "allow", updatedInput: input }; // no bridge → don't block
    }
    const command =
      toolName === "Bash" ? input.command || "" : toolName === "WebFetch" ? input.url || "" : JSON.stringify(input).slice(0, 200);
    const decision = await requestPermission({ tool: toolName, command: String(command) });
    if (decision === "reject") {
      return { behavior: "deny", message: "The user declined running " + toolName + "." };
    }
    if (decision === "always") alwaysAllow.add(toolName);
    return { behavior: "allow", updatedInput: input };
  }

  async function handlePrompt(cmd) {
    const abort = new AbortController();
    const readonly = cmd.agent === "plan"; // navigator/chat: guide only, no file writes
    const disallowed = [...NATIVE_WRITERS, ...(readonly ? WRITE_TOOLS : [])];
    // Auto-allow Tandem's own tools + read-only tools; Bash/WebFetch go through canUseTool.
    const allowed = [...TANDEM_TOOLS.filter((t) => !disallowed.includes(t)), "Read", "Grep", "Glob"];

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
        mcpServers: { tandem: tandemServer },
        allowedTools: allowed,
        disallowedTools: disallowed,
        permissionMode: "default",
        canUseTool,
        thinking: effortToThinking(cmd.effort), // reasoning effort → thinking budget
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

  return { handlePrompt, cancel, cancelAll, history, usage, compact, listModels };
}
