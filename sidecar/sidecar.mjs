// Loupe sidecar — the OpenCode backend adapter.
// Boots an OpenCode server via the official SDK, sends a prompt, and streams the
// assistant's reply to stdout as one JSON object per line (the protocol Neovim
// reads). Set LOUPE_DEBUG=1 for stderr diagnostics (never pollutes stdout).
//
// Protocol (stdout, one JSON object per line):
//   {"type":"session","id":"ses_…"}   session created
//   {"type":"delta","text":"…"}        an incremental chunk of the reply
//   {"type":"done"}                    the turn finished
//   {"type":"error","error":{…}}       something went wrong
//
// Usage:  node sidecar.mjs "your prompt here"
import { createOpencode } from "@opencode-ai/sdk";

const PROMPT = process.argv[2] || "Say hi in five words.";
const MODEL = { providerID: "opencode", modelID: "north-mini-code-free" };

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}
function debug(...a) {
  if (process.env.LOUPE_DEBUG) process.stderr.write(a.map(String).join(" ") + "\n");
}

// port: 0 → a random free port, so concurrent/repeated runs never collide.
const { client, server } = await createOpencode({ port: 0 });
debug("server booted at", server.url);

// Always shut the spawned server down, or it orphans and blocks the next run.
function shutdown(code) {
  try { server.close(); } catch {}
  process.exit(code);
}
process.on("SIGTERM", () => shutdown(0));
process.on("SIGINT", () => shutdown(0));

// Subscribe BEFORE prompting so no early events are missed.
const events = await client.event.subscribe();

const created = await client.session.create({ body: {} });
const sessionID = created.data.id;
emit({ type: "session", id: sessionID });

await client.session.promptAsync({
  path: { id: sessionID },
  body: { model: MODEL, parts: [{ type: "text", text: PROMPT }] },
});
debug("prompt sent");

for await (const event of events.stream) {
  const t = event.type;
  const p = event.properties || {};
  if (p.sessionID && p.sessionID !== sessionID) continue; // ignore other sessions

  if (t === "message.part.delta" && p.field === "text" && p.delta) {
    emit({ type: "delta", text: p.delta });
  } else if (t === "session.idle") {
    emit({ type: "done" });
    break;
  } else if (t === "session.error") {
    emit({ type: "error", error: p });
    break;
  }
}
shutdown(0);
