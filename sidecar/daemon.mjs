// Tandem persistent sidecar (daemon).
// Boots ONE OpenCode server and stays alive, handling many prompts across many
// sessions over stdin/stdout. This is what gives the bubble real memory: a
// session id can be reused, so its conversation history accumulates.
//
// stdin — one JSON command per line:
//   {"cmd":"prompt","tag":"t1","session":null,"text":"hi"}        // new session
//   {"cmd":"prompt","tag":"t2","session":"ses_x","text":"..."}    // continue session
//   {"cmd":"shutdown"}
//
// stdout — one JSON event per line, each carrying the originating request's tag:
//   {"type":"ready"}                              // daemon booted, send commands
//   {"tag":"t1","type":"session","id":"ses_x"}    // the session this turn uses
//   {"tag":"t1","type":"delta","text":"..."}      // a streamed chunk of the reply
//   {"tag":"t1","type":"done"}                    // turn finished
//   {"tag":"t1","type":"error","error":{...}}
import { createOpencode } from "@opencode-ai/sdk";
import readline from "node:readline";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const MODEL = { providerID: "opencode", modelID: "north-mini-code-free" };
const VERSION = "2026-07-04 tool-events";

// tandem_instruct: the Navigator gives the human ONE directive (a next step). Sticky,
// non-blocking — shown in the notification bar until dismissed / next asked.
const TANDEM_INSTRUCT_TOOL = `import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Give the human ONE directive — the next step for them to do (they write the code; you guide). It appears in their notification bar and stays until they dismiss it or ask for the next step. Issue ONE instruction, then stop and wait — do not dump multiple steps at once.",
  args: {
    instruction: tool.schema.string().describe("A short, concrete next step for the human to do"),
  },
  async execute(args) {
    const port = process.env.TANDEM_BRIDGE_PORT
    if (!port) return "tandem_instruct is only available inside the Tandem editor."
    await fetch("http://127.0.0.1:" + port + "/instruct", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ instruction: args.instruction }),
    })
    return "shown"
  },
})
`;

// tandem_journal: curate the workpackage's shared JOURNAL (a concise living brief —
// goal, current state, key decisions, approach). Replaces the journal with the given
// markdown. The journal is injected into every session in this workpackage, so keep it
// tight. tandem_backlog: add tasks and/or tick off finished ones.
const TANDEM_JOURNAL_TOOL = `import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Curate this workpackage's JOURNAL — a concise, always-current brief (goal, current state, key decisions, approach & constraints) that is injected into every session here. Pass the COMPLETE updated journal markdown; it replaces the old one. Keep it tight: capture decisions and context, not a play-by-play. Update it as decisions are made or the state changes.",
  args: {
    content: tool.schema.string().describe("The complete updated journal markdown (a concise brief)"),
  },
  async execute(args) {
    const port = process.env.TANDEM_BRIDGE_PORT
    if (!port) return "tandem_journal is only available inside the Tandem editor."
    await fetch("http://127.0.0.1:" + port + "/journal", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content: args.content }),
    })
    return "journal updated"
  },
})
`;

const TANDEM_BACKLOG_TOOL = `import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Update this workpackage's BACKLOG: add new concrete tasks and/or mark finished ones done. Does NOT rewrite the list, so the human's ordering and edits are preserved. Add tasks as you identify them from planning; tick items off as you complete them.",
  args: {
    add: tool.schema.array(tool.schema.string()).optional().describe("New tasks to append (highest priority first)"),
    complete: tool.schema.array(tool.schema.string()).optional().describe("Texts of existing tasks to mark done (matched by text)"),
  },
  async execute(args) {
    const port = process.env.TANDEM_BRIDGE_PORT
    if (!port) return "tandem_backlog is only available inside the Tandem editor."
    await fetch("http://127.0.0.1:" + port + "/backlog", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ add: args.add || [], complete: args.complete || [] }),
    })
    return "backlog updated"
  },
})
`;

// tandem_ask: ask the user a question and BLOCK until they answer (returned as the
// tool result). tandem_notify: fire-and-forget status line. Both reach the user
// through the same bridge as the edit tools.
const TANDEM_ASK_TOOL = `import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Ask the user a question and wait for their answer. Use whenever you need a decision from them — a name, a choice between approaches, confirmation before a structural change. In low autonomy, ask often (before naming functions/variables/files or making structural choices). Returns the user's answer.",
  args: {
    question: tool.schema.string().describe("The question to ask the user"),
  },
  async execute(args) {
    const port = process.env.TANDEM_BRIDGE_PORT
    if (!port) return "tandem_ask is only available inside the Tandem editor."
    const res = await fetch("http://127.0.0.1:" + port + "/ask", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: args.question }),
    })
    const out = await res.json().catch(() => ({}))
    return out.message || "(no answer)"
  },
})
`;

const TANDEM_NOTIFY_TOOL = `import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Briefly tell the user what you are doing or about to do (a short status line). Non-blocking: it shows a small notification and returns immediately. Use for significant steps, sparingly.",
  args: {
    message: tool.schema.string().describe("A short status message for the user"),
  },
  async execute(args) {
    const port = process.env.TANDEM_BRIDGE_PORT
    if (!port) return "tandem_notify is only available inside the Tandem editor."
    await fetch("http://127.0.0.1:" + port + "/notify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message: args.message }),
    })
    return "shown"
  },
})
`;

// tandem_region: replace just the region the user selected/marked. Returns ONLY that
// region's code (not the whole file) — Tandem places it between the marks while the
// user can keep editing elsewhere. Posts to the same bridge as tandem_write.
const TANDEM_REGION_TOOL = `import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Replace the region of code the user has selected/marked in their editor. Return ONLY the replacement code for that region — NOT the whole file. Use this whenever the user asks you to implement, fill in, or change a selected region.",
  args: {
    code: tool.schema.string().describe("The replacement code for the selected region only"),
  },
  async execute(args) {
    const port = process.env.TANDEM_BRIDGE_PORT
    if (!port) return "tandem_region is only available inside the Tandem editor."
    const res = await fetch("http://127.0.0.1:" + port + "/region", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code: args.code }),
    })
    const out = await res.json().catch(() => ({}))
    return out.message || "applied"
  },
})
`;

// The tandem_write tool source. Deployed (below) into a Tandem-owned opencode config
// dir so the model can call it in ANY project. Instead of writing to disk, it POSTs
// the edit to the daemon's bridge, which relays to Neovim's typewriter. The `await
// fetch` blocks until Neovim is done — the suspension point for interrupt/resume.
const TANDEM_WRITE_TOOL = `import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Write code into the user's editor through Tandem. The ONLY way to create or modify a file; the human watches it typed in and can interrupt. Only works inside the Tandem Neovim plugin.",
  args: {
    file: tool.schema.string().describe("Path of the file to create or edit"),
    content: tool.schema.string().describe("The complete new contents of the file"),
  },
  async execute(args) {
    const port = process.env.TANDEM_BRIDGE_PORT
    if (!port) return "tandem_write is only available inside the Tandem editor; use the normal edit tools instead."
    const res = await fetch("http://127.0.0.1:" + port + "/edit", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ file: args.file, content: args.content }),
    })
    const out = await res.json().catch(() => ({}))
    return out.message || "applied"
  },
})
`;

// Fallback system prompt — only used if Neovim doesn't send a per-role one (it
// normally does, via build_system). Code goes in fenced markdown blocks, which Tandem
// captures to offer as ghost text; edits into the buffer happen through the tandem_*
// tools, never prose tags.
const SYSTEM = [
  "You are assisting inside a code editor; the user reads your reply in a small chat bubble.",
  "When part of your answer is concrete code the user could put in a file, place it in a fenced",
  "``` markdown code block, with all explanation as prose OUTSIDE the fences. Tandem captures",
  "fenced blocks so the user can project one as ghost text at their cursor.",
  "Do NOT fence tiny inline snippets that are part of a sentence — only standalone code blocks.",
].join("\n");

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}
function debug(...a) {
  if (process.env.TANDEM_DEBUG) process.stderr.write(a.map(String).join(" ") + "\n");
}

// ── tandem_write deployment + edit bridge (must precede createOpencode) ──
// Deploy the tool into a Tandem-OWNED config dir; OPENCODE_CONFIG_DIR keeps the
// user's model auth working (verified) without touching project/global config.
const TANDEM_CFG_DIR = path.join(os.homedir(), ".cache", "tandem", "opencode");
fs.mkdirSync(path.join(TANDEM_CFG_DIR, "tools"), { recursive: true });
fs.writeFileSync(path.join(TANDEM_CFG_DIR, "tools", "tandem_write.js"), TANDEM_WRITE_TOOL);
fs.writeFileSync(path.join(TANDEM_CFG_DIR, "tools", "tandem_region.js"), TANDEM_REGION_TOOL);
fs.writeFileSync(path.join(TANDEM_CFG_DIR, "tools", "tandem_ask.js"), TANDEM_ASK_TOOL);
fs.writeFileSync(path.join(TANDEM_CFG_DIR, "tools", "tandem_notify.js"), TANDEM_NOTIFY_TOOL);
fs.writeFileSync(path.join(TANDEM_CFG_DIR, "tools", "tandem_instruct.js"), TANDEM_INSTRUCT_TOOL);
fs.writeFileSync(path.join(TANDEM_CFG_DIR, "tools", "tandem_journal.js"), TANDEM_JOURNAL_TOOL);
fs.writeFileSync(path.join(TANDEM_CFG_DIR, "tools", "tandem_backlog.js"), TANDEM_BACKLOG_TOOL);
process.env.OPENCODE_CONFIG_DIR = TANDEM_CFG_DIR;

const pendingEdits = new Map(); // editID -> pending http response (the blocked tool)
let editN = 0;
function takeBody(req, res, fn) {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    let e = {};
    try { e = JSON.parse(body || "{}"); } catch {}
    const id = "e" + ++editN;
    pendingEdits.set(id, res);
    fn(id, e);
  });
}
const bridge = http.createServer((req, res) => {
  if (req.method === "POST" && req.url === "/edit") {
    takeBody(req, res, (id, e) => send({ type: "edit", id, file: e.file, content: e.content }));
  } else if (req.method === "POST" && req.url === "/region") {
    takeBody(req, res, (id, e) => send({ type: "region", id, content: e.code }));
  } else if (req.method === "POST" && req.url === "/ask") {
    // blocking: relay the question, resolve when Neovim replies with the answer
    takeBody(req, res, (id, e) => send({ type: "ask", id, question: e.question }));
  } else if (req.method === "POST" && req.url === "/notify") {
    // fire-and-forget: show it and return immediately
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let e = {};
      try { e = JSON.parse(body || "{}"); } catch {}
      send({ type: "notify", message: e.message });
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"message":"shown"}');
    });
  } else if (req.method === "POST" && req.url === "/journal") {
    // fire-and-forget: Neovim writes the workpackage journal
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let e = {};
      try { e = JSON.parse(body || "{}"); } catch {}
      send({ type: "journal", content: e.content });
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"message":"journal updated"}');
    });
  } else if (req.method === "POST" && req.url === "/backlog") {
    // fire-and-forget: Neovim adds/completes backlog tasks
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let e = {};
      try { e = JSON.parse(body || "{}"); } catch {}
      send({ type: "backlog", add: e.add, complete: e.complete });
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"message":"backlog updated"}');
    });
  } else if (req.method === "POST" && req.url === "/instruct") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let e = {};
      try { e = JSON.parse(body || "{}"); } catch {}
      send({ type: "instruct", instruction: e.instruction });
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"message":"shown"}');
    });
  } else {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => bridge.listen(0, "127.0.0.1", r));
process.env.TANDEM_BRIDGE_PORT = String(bridge.address().port);
debug("tandem bridge on", bridge.address().port);

// Gate side-effecting native tools behind a human OK (bash, webfetch). Reads/greps
// stay auto-allowed; Tandem's own tools have their own gate (the typewriter). This
// makes OpenCode raise permission.updated events we relay to the editor.
// Kept mutable so config.update (for per-model reasoning effort) can resend the WHOLE
// config and never accidentally drop the permission rules.
const daemonConfig = { permission: { bash: "ask", webfetch: "ask" } };
const { client, server } = await createOpencode({ port: 0, config: daemonConfig });
debug("daemon up at", server.url);

// Apply a reasoning effort to an OpenCode model by setting its options.reasoningEffort
// and pushing the whole config live (what the TUI's Ctrl+T does under the hood).
async function setOpencodeEffort(model, effort) {
  if (!model || !model.providerID || !model.modelID) return;
  daemonConfig.provider = daemonConfig.provider || {};
  const prov = (daemonConfig.provider[model.providerID] = daemonConfig.provider[model.providerID] || {});
  prov.models = prov.models || {};
  const m = (prov.models[model.modelID] = prov.models[model.modelID] || {});
  m.options = m.options || {};
  if (effort) m.options.reasoningEffort = effort;
  else delete m.options.reasoningEffort;
  try {
    await client.config.update({ body: daemonConfig });
  } catch (e) {
    debug("config.update (effort) failed", e);
  }
}

// List the models actually available through the backends (no hardcoding in Neovim):
// every OpenCode provider's models (tagged with whether they support reasoning), plus
// the Claude backend's models. Sent back as { type:"models", models:[…] }.
async function listModels(tag) {
  const out = [];
  try {
    const res = await client.config.providers();
    const providers = (res.data && res.data.providers) || [];
    for (const prov of providers) {
      const models = prov.models || {};
      const entries = Array.isArray(models) ? models : Object.values(models);
      for (const m of entries) {
        if (!m || !m.id) continue;
        out.push({
          backend: "opencode",
          providerID: prov.id || m.providerID,
          modelID: m.id,
          label: (prov.name ? prov.name + " · " : "") + (m.name || m.id),
          reasoning: !!(m.capabilities && m.capabilities.reasoning),
        });
      }
    }
  } catch (e) {
    debug("opencode providers failed", e);
  }
  try {
    const b = await getClaude();
    for (const m of await b.listModels()) out.push(m);
  } catch (e) {
    debug("claude listModels failed", e);
  }
  send({ tag, type: "models", models: out });
}

// ── Tool-permission bridge ──────────────────────────────────────
// Both backends funnel "may I run this tool?" through here: we ask the editor and
// block until the human answers once / always / reject. `permission_reply` (stdin)
// resolves the waiting promise. Shared by the OpenCode event handler below and the
// Claude backend's canUseTool.
const pendingPermissions = new Map(); // id -> resolve
let permN = 0;
function requestPermission({ tool, command }) {
  return new Promise((resolve) => {
    const id = "perm" + ++permN;
    pendingPermissions.set(id, resolve);
    send({ type: "permission", id, tool, command: command || "" });
  });
}
function shutdown(code) {
  try { bridge.close(); } catch {}
  try { server.close(); } catch {}
  process.exit(code);
}
process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));

// One global event stream for the whole server; route each event to the request
// that owns its session. `active` maps a sessionID to the request currently
// streaming from it.
const active = new Map(); // sessionID -> { tag }
const partType = new Map(); // partID -> "text" | "reasoning" | ... (to filter reasoning)
const toolPhase = new Map(); // callID -> last tool phase emitted ("running"|"done")
let lastStatus = ""; // dedupe the one-line status we push to the editor

// Trim a tool's output for display (bash etc. can be huge). Keeps the head.
function trimOutput(s, maxLines = 12, maxChars = 1000) {
  if (!s) return "";
  let lines = String(s).split("\n");
  let cut = lines.length > maxLines;
  lines = lines.slice(0, maxLines);
  let out = lines.join("\n");
  if (out.length > maxChars) {
    out = out.slice(0, maxChars);
    cut = true;
  }
  return cut ? out + "\n…" : out;
}

// A concise "what the AI is doing now" label from a tool call (falls back when
// OpenCode doesn't supply its own title).
function toolLabel(tool, input = {}) {
  const base = (s) => (typeof s === "string" && s ? s.split("/").pop() : "");
  switch (tool) {
    case "read": return "reading " + (base(input.filePath || input.path) || "a file");
    case "write": case "edit": case "apply_patch": case "tandem_write":
      return "writing " + (base(input.file || input.filePath) || "a file");
    case "bash": return "running: " + String(input.command || input.description || "command").replace(/\s+/g, " ").slice(0, 40);
    case "grep": return "searching" + (input.pattern ? ' "' + String(input.pattern).slice(0, 24) + '"' : "");
    case "glob": case "list": return "finding files";
    case "webfetch": return "fetching " + (base(input.url) || "");
    case "task": return "delegating a subtask";
    default: return String(tool).replace(/_/g, " ");
  }
}

const events = await client.event.subscribe();
(async () => {
  for await (const event of events.stream) {
    const p = event.properties || {};
    // Permission asks arrive as their own event (not tied to a streaming request):
    // ask the editor, then reply once/always/reject. Handle before the `active` guard.
    if (event.type === "permission.updated" && p.id && p.sessionID) {
      const command =
        (p.metadata && (p.metadata.command || p.metadata.cmd || p.metadata.url)) || p.title || p.type;
      requestPermission({ tool: p.type, command: String(command) }).then((decision) => {
        client
          .postSessionIdPermissionsPermissionId({
            path: { id: p.sessionID, permissionID: p.id },
            body: { response: decision === "always" ? "always" : decision === "reject" ? "reject" : "once" },
          })
          .catch((e) => debug("permission reply error", e));
      });
      continue;
    }
    const req = active.get(p.sessionID);
    if (!req) continue;
    if (event.type === "message.part.updated" && p.part) {
      const part = p.part;
      partType.set(part.id, part.type); // learn each part's type
      // Surface what the AI is doing as a one-line status (global; the editor shows
      // it in the activity indicator). Deduped so we don't spam identical lines.
      let label = null;
      if (part.type === "tool" && part.state) {
        const st = part.state.status;
        const title = part.state.title || toolLabel(part.tool, part.state.input);
        const key = part.callID || part.id;
        // Full tool-call events (name + title + output) for the activity bar and the
        // command-centre transcript — beyond the one-line status. Emit start once,
        // then done/error once.
        if (st === "running" || st === "pending") {
          label = title;
          if (toolPhase.get(key) !== "running") {
            toolPhase.set(key, "running");
            send({ type: "tool", phase: "running", tool: part.tool, title, session: part.sessionID });
          }
        } else if (st === "completed" && toolPhase.get(key) !== "done") {
          toolPhase.set(key, "done");
          send({ type: "tool", phase: "done", tool: part.tool, title, output: trimOutput(part.state.output), session: part.sessionID });
        } else if (st === "error" && toolPhase.get(key) !== "done") {
          toolPhase.set(key, "done");
          send({ type: "tool", phase: "error", tool: part.tool, title, error: String(part.state.error || "error"), session: part.sessionID });
        }
      } else if (part.type === "reasoning") {
        label = "thinking…";
      }
      if (label && label !== lastStatus) {
        lastStatus = label;
        send({ type: "status", label });
      }
    } else if (event.type === "message.part.delta" && p.field === "text" && p.delta) {
      // Drop the model's "thinking" — only stream actual answer (text) parts.
      if (partType.get(p.partID) !== "reasoning") {
        send({ tag: req.tag, type: "delta", text: p.delta });
      }
    } else if (event.type === "session.idle") {
      lastStatus = ""; // reset so the next turn re-emits its status
      toolPhase.clear();
      send({ tag: req.tag, type: "done" });
      active.delete(p.sessionID);
    } else if (event.type === "session.error") {
      send({ tag: req.tag, type: "error", error: p });
      active.delete(p.sessionID);
    }
  }
})().catch((e) => debug("event loop error", e));

async function handlePrompt(cmd) {
  let sid = cmd.session;
  if (cmd.fork && sid) {
    // Fork: a new session that inherits the parent's history, then diverges —
    // a context-preserving side thread that won't pollute the original.
    const forked = await client.session.fork({ path: { id: sid } });
    sid = forked.data.id;
  } else if (!sid) {
    const created = await client.session.create({ body: {} });
    sid = created.data.id; // a fresh session = fresh memory
  }
  active.set(sid, { tag: cmd.tag });
  send({ tag: cmd.tag, type: "session", id: sid });
  // Reasoning effort: OpenCode reads it from the model's config options, so push it
  // live before the turn (the model carries whether it's applicable).
  if (cmd.model && cmd.effort !== undefined) {
    await setOpencodeEffort(cmd.model, cmd.effort);
  }
  // Reusing `sid` here is the whole point: the session keeps its history.
  // Default to the read-only `plan` agent so a chat turn never edits files;
  // edit-capable agents (e.g. "build") are opt-in via cmd.agent later (§3.13).
  await client.session.promptAsync({
    path: { id: sid },
    body: {
      model: cmd.model || MODEL,
      agent: cmd.agent || "plan",
      system: cmd.system || SYSTEM, // Neovim assembles a per-role system from agent files
      tools: cmd.tools, // per-role gating, e.g. Driver: { write:false, edit:false, patch:false }
      parts: [{ type: "text", text: cmd.text }],
    },
  });
}

// The Claude backend (Agent SDK) is loaded lazily the first time a command asks for
// it, so the OpenCode path never pays for it. It uses the user's Claude Code login
// (the SDK spawns the claude binary) — no API key. Speaks the same event protocol.
let claudeBackend = null;
async function getClaude() {
  if (!claudeBackend) {
    const { createClaudeBackend } = await import("./backends/claude.mjs");
    claudeBackend = createClaudeBackend({ send, cwd: process.cwd(), defaultSystem: SYSTEM, requestPermission });
  }
  return claudeBackend;
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  line = line.trim();
  if (!line) return;
  let cmd;
  try { cmd = JSON.parse(line); } catch { return; }
  const claude = cmd.backend === "claude"; // route session-scoped commands per backend
  if (cmd.cmd === "list_models") {
    listModels(cmd.tag);
  } else if (cmd.cmd === "prompt") {
    if (claude) {
      getClaude().then((b) => b.handlePrompt(cmd)).catch((e) => send({ tag: cmd.tag, type: "error", error: String(e) }));
    } else {
      handlePrompt(cmd).catch((e) => send({ tag: cmd.tag, type: "error", error: String(e) }));
    }
  } else if (cmd.cmd === "cancel" && cmd.session) {
    // Abort the running turn for this session (the user hit cancel).
    if (claude) {
      getClaude().then((b) => b.cancel(cmd.session)).catch((e) => debug("abort error", e));
    } else {
      client.session.abort({ path: { id: cmd.session } }).catch((e) => debug("abort error", e));
    }
  } else if (cmd.cmd === "cancel_all") {
    // Abort every running turn (global cancel) across both backends.
    for (const sid of active.keys()) {
      client.session.abort({ path: { id: sid } }).catch((e) => debug("abort error", e));
    }
    if (claudeBackend) claudeBackend.cancelAll();
  } else if (cmd.cmd === "history" && cmd.session && claude) {
    getClaude().then((b) => b.history(cmd)).catch((e) => send({ tag: cmd.tag, type: "error", error: String(e) }));
  } else if (cmd.cmd === "usage" && cmd.session && claude) {
    getClaude().then((b) => b.usage(cmd)).catch((e) => send({ tag: cmd.tag, type: "usage", error: String(e) }));
  } else if (cmd.cmd === "compact" && cmd.session && claude) {
    getClaude().then((b) => b.compact(cmd)).catch((e) => send({ tag: cmd.tag, type: "error", error: String(e) }));
  } else if (cmd.cmd === "history" && cmd.session) {
    // Return the session's prior messages (role + concatenated text parts).
    client.session
      .messages({ path: { id: cmd.session } })
      .then((res) => {
        const msgs = (res.data || [])
          .map((m) => ({
            role: m.info?.role || "?",
            text: (m.parts || [])
              .filter((p) => p.type === "text" && p.text)
              .map((p) => p.text)
              .join(""),
          }))
          .filter((m) => m.text.trim() !== "");
        send({ tag: cmd.tag, type: "history", messages: msgs });
      })
      .catch((e) => send({ tag: cmd.tag, type: "error", error: String(e) }));
  } else if (cmd.cmd === "usage" && cmd.session) {
    // Token/cost usage: sum message costs, take the latest context size.
    client.session
      .messages({ path: { id: cmd.session } })
      .then((res) => {
        let cost = 0, input = 0, output = 0, context = 0;
        for (const m of res.data || []) {
          const t = m.info?.tokens;
          if (t) {
            cost += m.info.cost || 0;
            input += t.input || 0;
            output += t.output || 0;
            context = (t.input || 0) + (t.cache?.read || 0) + (t.cache?.write || 0);
          }
        }
        send({ tag: cmd.tag, type: "usage", cost, input, output, context });
      })
      .catch((e) => send({ tag: cmd.tag, type: "usage", error: String(e) }));
  } else if (cmd.cmd === "compact" && cmd.session) {
    // Compact (summarize) the session to shrink the context.
    const model = cmd.model || MODEL;
    client.session
      .summarize({ path: { id: cmd.session }, body: { providerID: model.providerID, modelID: model.modelID } })
      .then(() => send({ tag: cmd.tag, type: "compacted" }))
      .catch((e) => send({ tag: cmd.tag, type: "error", error: String(e) }));
  } else if (cmd.cmd === "edit_done") {
    // Neovim finished applying an edit; unblock the tandem_write tool that's waiting.
    const res = pendingEdits.get(cmd.id);
    if (res) {
      pendingEdits.delete(cmd.id);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ message: cmd.message || "applied" }));
    }
  } else if (cmd.cmd === "permission_reply") {
    // Neovim answered a tool-permission ask (once / always / reject).
    const resolve = pendingPermissions.get(cmd.id);
    if (resolve) {
      pendingPermissions.delete(cmd.id);
      resolve(cmd.decision || "reject");
    }
  } else if (cmd.cmd === "shutdown") {
    shutdown(0);
  }
});

// Tell the client we're ready to accept commands.
send({ type: "ready", version: VERSION });
debug("listening on stdin");
