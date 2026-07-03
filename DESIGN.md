# Tandem — Design Document

> Working title. A *tandem* is the small magnifier used to examine fine detail up
> close. Rename freely.

Status: **brainstorm / pre-implementation**. This doc is the durable reference so
the vision survives across sessions. It is meant to be read, edited, and
*interrogated* — ask the agent about it like any other file.

---

## 1. Mission

**Remove the "I have to understand everything before I can start" barrier — by
putting an expert in the editor who lets you start anyway, and learn on the way
up instead of as a prerequisite.**

The user is a capable engineer who (a) is losing hands-on skill by architecting
instead of building, (b) can't retain decisions made passively in long agent
chats, and (c) procrastinates because their brain demands full understanding
before starting. Existing tools (Claude Code, OpenCode) optimize for *throughput*
— the human approves at the end. Tandem optimizes for the human staying **in the
loop, in the editor, learning as they go**, while still getting a real speed-up.

### Design tenets

1. **Learning over throughput.** Retention comes from active recall and
   generation effort. Features should create mild, *chosen* cognitive effort —
   not passive watching.
2. **The editor is the interface, not a chat panel.** Reject the long scrolling
   transcript as the primary surface.
3. **Located, not linear.** Interactions happen *at the place and moment they're
   relevant*, anchored to code.
4. **Real-time control of autonomy.** The human dials how much the agent does,
   and can change it mid-task without restarting.
5. **Start before you understand.** The tool exists to get a nervous
   perfectionist moving, then teach on the climb.

---

## 2. Founding user story (the "golden path")

The user wants to build a project they know nothing about (in fact: *this*
plugin). The target flow:

1. Quick planning chat in a central popup; dump ideas, produce a plan written out
   *live* (typewriter), interruptible and questionable as it forms.
2. Be instructed to create/open a file; jump into it.
3. Open the bubble at the cursor: "what are we trying to do in this file? how do I
   start?"
4. Ask for example code; **watch it being written**, step through it, ask
   questions inline, close the bubble.
5. Refer back to the plan; ask questions about it; ask for an example.
6. Go back to the file, write some lines by hand.
7. Open the bubble: "write the whole networking section." It does.
8. Open the files it created/edited and have it **step through the changes line
   by line**, with the chance to ask questions — *or* read them yourself and ask
   it to justify choices.

This loop — plan, start, write, hand off, walk back through, understand — is the
product. If it nails this, it works.

---

## 3. Core model

### 3.1 The controllable apply-stream (the spine)

**Decouple generation from application.** The model streams a full edit into a
*queue* as fast as it can. A Neovim-side "typewriter" drains that queue into the
buffer at a controllable **rate and granularity** (char / word / line /
function). Generation is fast; application is a UI animation *you* control.

From this one idea, several features fall out for free:

- **"See it being written"** = playing back an already-generated edit at human
  speed.
- **Granularity dial** = how big each drain step is.
- **Pause / step / resume** = stop/start the drain.
- **Decision points** (below) = *breakpoints* in the drain.
- **Replayable changes** (below) = a stored apply-stream you can watch later.

### 3.2 Decisions are breakpoints, not (only) tool calls

A "decision" is any consequential choice — including ones **baked into generated
code** (a variable name, a timeout, "singleton vs not"), not just tool calls. The
model tags such spans with metadata: *what it chose, the alternatives, why*. When
the typewriter reaches a tagged span it **pauses there**, opens the bubble at that
location, and waits. Confirm → continue. Edit → substitute. So decisions reuse the
exact same machinery as granularity stepping.

There are **two kinds of pause**, and the distinction matters:

- **Application-side pause** — the code is already generated; you're just
  stepping through it. (The env-var *name* is this: it wrote the file, a rename is
  a cheap find/replace.) Post-hoc confirmation.
- **Generation-side pause** — the model genuinely cannot continue until you
  answer, because your answer changes downstream code ("REST or gRPC?"). It must
  ask *before* producing the rest.

The **autonomy dial** decides which decisions are surfaced and which kind of pause
they trigger.

### 3.3 The gate is a conversation, not a form

Anti-pattern (what Claude Code / OpenCode / batch question UIs do): generate
everything, then dump a pile of questions to answer-and-submit. Tandem instead
opens a **tiny scoped chat in the bubble** at each breakpoint: one question, fully
interactive. "I don't get it" → it elaborates *right there* → back-and-forth until
you give a real answer → it continues to the next breakpoint. The difference is
**temporal**: the question happens at the moment and place it's relevant.

### 3.4 The pairing model (the USP — canonical; supersedes the old Coach/Pair/Pilot/Auto dial)

Tandem is built on pair-programming idioms. The AI takes a **role**, set by injecting
a per-mode **agent/skill markdown** that forces both behaviour and output structure
(tags). Change it live, anytime.

**Roles:**
- **Driver** — the AI writes; *you navigate.* Code lands as **real committed edits**
  (typewriter). Set **Autonomy**: High ("go do it, tell me when done" — few toasts)
  / Medium / Low ("narrate and ask before each step").
- **Navigator** — the AI guides; *you write.* Code lands as **suggestions / ghost
  text** (you're driving). Set **Guidance**: High (a direction only) / Medium / Low
  (exact step-by-step).
- **Neutral** — a normal assistant: ideating, planning, tool calls.
- **Coach** — a *separate Socratic toggle* layerable over any level: don't just tell
  me, help me get there myself.

**Engine split by Driver autonomy (confirmed):**
- **Low/Medium Driver** = the model *proposes* tagged edits and **Tandem types them
  in** via the typewriter — watchable, pace-controlled, pausable, gated. Tandem owns
  the write. (Same machinery as Navigator; only the *rendering* differs — Navigator
  → ghost, Driver → committed.)
- **High Driver** = OpenCode's `build` agent runs the real agentic loop and **writes
  files itself**; you get toasts + a summary + a recap. The only place OpenCode owns
  the write.

**Mechanism:** each Role+Level = an injected agent/skill file + a tag contract;
Tandem routes the tagged output (ghost vs commit, toast vs popup vs panel). The
generalization of §3.13.

### 3.4.1 The three surfaces

1. **Main chat** — a central Telescope/LazyGit-style window: input box at bottom,
   transcript above; live **attribute labels** (model, effort, role, level,
   workpackage, session — tab-navigable to change); a **to-do / notification panel**.
   The command centre: planning, full history, workpackage/session management,
   non-coding work, tools. Open anytime.
2. **Toasts** — a small bottom notification bar; the AI announces actions /
   questions / instructions (tag-driven). Acknowledge with a shortcut (posts an ack
   into the session), open the chat for detail, answer a quick **question popup**,
   or — Navigator — hit **"next instruction."** "Switch to this buffer to follow me"
   prompts gate the Driver's continuation on your accept.
3. **Bubbles** — the located ones (line/selection/file), given the *same* shape as
   the main chat (input + transcript + attribute labels), small and at the cursor.
   Ask the Navigator / steer the Driver in context.

### 3.4.2 Recap (Navigator over the diff — key for retention)

After autonomous (high-Driver) work, the AI walks you through what it did **in the
codebase**, not the chat — the antidote to high-autonomy amnesia, and the
realization of §3.5. It's just **Navigator mode pointed at a change-set**:
- Grounded in the *real* diff (OpenCode session diff / `file.edited`) so it can't
  hallucinate the summary.
- The AI emits tagged recap entries (`<tandem:recap file="…" loc="…" why="…">…`), one
  per change → each becomes a **stop**.
- Layout: right split = recap panel (what / where / why); left = the code;
  **next/prev jumps the cursor to each change**; at each stop a **bubble** asks "why
  this?" / justify / change it.
- Later flourish: *replay* each change as a typewriter animation at its stop.

### 3.5 Located, replayable changes (kills the linear log)

Every change is recorded as a **replayable apply-stream tied to a location**. This
decouples *when the edit happened* from *when you watch it*:

- **Pair/Pilot**: when an edit targets another file, open it (window or split) and
  watch the typewriter live — "follow the agent."
- **Auto**: edit in the background, but store each change as a replayable stream.
  Later, open the file, hit **review**, and watch the change *type itself out* at
  the location with the bubble narrating. Same animation, deferred.

A refactor across 8 files is not a wall of diffs in a chat panel — it's 8 located,
replayable, narratable change-events you visit intentionally.

### 3.6 The journal (history = memory = queryable artifact)

One append-only **project journal** of intentions, decisions, and changes, with
three faces:

1. **Memory** injected into future sessions.
2. **Browsable** in the inbox window (below).
3. **Queryable in natural language** — "why did we do this? what were my
   intentions here?" You interrogate your own past reasoning.

Persist it as a file so you can do to it what you do to code: open it, ask about
it, edit it. Your history becomes another context surface, not a throwaway
transcript.

### 3.7 The inbox / command window

A floating window that can pop over any buffer (manually or automatically),
listing **outstanding actions** ("open this file to continue"), pending decisions,
thoughts, and summaries. Click an item → jump to its buffer/location. This is the
non-linear navigation hub that replaces scrolling the chat. The full transcript is
still openable on purpose — as a file you can read and question — but it is *not*
the default surface.

### 3.8 The one hard rule: regenerate, don't reconcile

Three situations are secretly the same problem — *the human changed something
while there's un-applied generated code waiting*:

- a decision that changes downstream code,
- an interrupt where you hand-edit mid-stream,
- a live answer that invalidates what was generated.

**Rule: throw away the stale tail and regenerate.** Send the model the current
buffer state + remaining intent and let it re-produce the rest. Regeneration is
cheap; diff/position reconciliation (operational transforms) is a tar pit. Accept
this one rule and a huge amount of complexity evaporates.

### 3.9 Three output channels (never conflate them)

The agent's output flows through three distinct surfaces. Confusing them is the
#1 early mistake.

1. **Conversation — the bubble.** Q&A, explanations, reasoning, and decision
   questions render *inside the bubble*, which is a real chat surface — a mini
   OpenCode/Claude window anchored to the code. It grows as the reply streams,
   caps at a fixed height, and scrolls. The conversation *lives here*; it does
   **not** write into the file. Conversations are persisted and **recallable** so
   you can re-read what was said (ties to the journal, §3.6). Rendered as markdown
   with syntax-highlighted code (treesitter), like OpenCode, for readability —
   polish task, not core.
2. **Commit — the typewriter.** ONLY when the agent edits files. Streams
   characters into the code buffer at controllable granularity (§3.1). The *only*
   channel that mutates code; inserts at the right location rather than rewriting
   the buffer.
3. **Preview — ghost text.** Optional, non-committal suggestions/examples as
   greyed virtual text (extmarks); read, accept, or dismiss. File untouched.

A plain question yields a reply *in the bubble*. A "write the networking section"
request yields *both*: discussion in the bubble **and** code typing into the file.

Bootstrap mistake worth recording: piping the *reply* into the code via the
typewriter. Wrong — a reply is conversation (channel 1); only edits use the
typewriter (channel 2). The stub that typed answers into the buffer was test
wiring, not the design.

Corollary tenet: **teaching/example/conversation content renders in the editor
(bubble or ghost), never in a side panel that forces a context switch.** Extmarks
and floating windows are the shared primitives behind all three channels and the
decision markers — build them early.

### 3.12 Sessions & context model

**Current state:** the spike sidecar creates a NEW session per prompt (one-shot) —
fine for proving streaming, wrong as the design. New session = total amnesia.

**How harnesses work:** a *session* is a conversation thread; each prompt is sent
with the accumulated history, so the model "remembers." Past the context window,
*compaction* summarizes older messages (lossy, and invisible to you).
OpenCode/Claude Code default to one long session per chunk of work.

**The trap:** naively funnelling every Tandem bubble into one ever-growing session
reintroduces the exact problem Tandem exists to kill — an opaque linear transcript
you can't hold in your head, lossy after compaction, tangling real work with
throwaway questions.

**Tandem's answer — context is *assembled* per question from three sources:**
1. **Located context** — code under cursor / selection / file.
2. **Session context** — the conversation thread the question belongs to.
3. **Project context = the journal (§3.6)** — durable plan, decisions, intentions;
   structured, injected into prompts, and *visible/editable/queryable by you*.

**Session tiers:**
- **Working session(s)** — long-lived, tied to a unit of work ("the networking
  module"). Related questions attach here → continuity without re-explaining.
  Switchable; compaction keeps them viable.
- **Ephemeral session** — throwaway one-offs that must NOT pollute the working
  thread.

**The differentiator:** important context lives in the **journal**, not only inside
an opaque LLM session — so a fresh/ephemeral session is still grounded, you never
re-explain the plan, related questions share a session, and the "memory" is
externalized into something you can see and edit (the retention thesis, §1).

**Control (located + intentional):** the bubble shows which session/context a
question is bound to; default = active working session; a modifier = ask
ephemerally. You choose, visibly.

**Architecture impact:** the sidecar must evolve from one-shot to **persistent** —
one long-lived process per Neovim instance, holding the OpenCode server and routing
prompts to named sessions (`promptAsync` takes a session id). Neovim tells it which
session each prompt belongs to, over stdin.

**Hierarchy (refined with user):**
- **Work Package** — a goal + overall plan, created via the central planning
  window. The unit you "switch into."
- **Sessions** — one or more conversation threads *inside* a work package (the
  continuity unit).
- **Bubbles** — individual located interactions, each attached to a session.
- **Ephemeral** — attached to nothing.
- The **journal (§3.6)** is durable memory cross-cutting all work packages.

Each bubble defaults to the **last-used work package/session** unless you choose
otherwise. Starting a new work package opens the planning window; everything after
associates with it.

**Forking (OpenCode supports `--fork`):** a fork branches a session at a point; the
branch inherits all prior context then diverges, leaving the original untouched.
Tandem's use — side-questions split in two:
1. *Standalone* ("how do I free memory in Zig?") → fresh ephemeral session, no
   context, no pollution.
2. *Context-needing but non-polluting* ("why did we make this async?") → **fork the
   working session**, ask with full context, main thread stays clean.

**The abstraction thesis (core):** Tandem is an orchestration layer over OpenCode's
session/memory primitives. The user operates at the level of *intent* ("start a
work package", "ask about this", "coach me", "go build this"); Tandem decides in the
background which session to talk to, whether to fork, and what journal context to
inject. Raw sessions/compaction/forks are plumbing the user should almost never
think about. **This abstraction layer is the product; OpenCode is the engine.**

**Open decisions:** default session granularity (one working session vs per-file vs
per-plan); when to build the journal (it's the linchpin); auto vs manual session
assignment.

### 3.13 Structured output contract & injected agents/skills (keystone)

To the model, its reply is just text — it cannot tell "example" from "prose" from
"an edit" from "a decision." So Tandem must make the model **tag** its output, then
parse and route it. **Every routing feature depends on this one mechanism** — the
three channels (§3.9), decision markers (§3.3), tool handling (§3.11).

Mechanism: inject an OpenCode **agent/skill** (or system preamble) that enforces an
output contract, e.g.:

    <tandem:suggest target="foo.zig:42"> ...code... </tandem:suggest>
    <tandem:decision q="env var name?" default="DATABASE_URL"> ...
    <tandem:edit file="..."> ...code... </tandem:edit>

Tandem parses the stream for these markers and routes each span:
- prose → chat bubble;
- **suggestion → shown in chat AND projectable into the buffer as ghost text** the
  user types over or applies (the least-automative mode — model proposes at a
  location, user writes). Default target = chat; user/context decides whether to
  project. Model may *hint* a target; user decides.
- edit → typewriter commit (§3.1);
- decision → gate popup (§3.3).

OpenCode agents/skills are the native place to impose this (user already has
`~/.config/opencode/skills` + agents; server exposes `/api/agent`, `/api/skill`).

**Modes = injected agent/skill configs.** The autonomy dial (§3.4) is *implemented*
by which agent Tandem injects: Coach = Socratic, tags suggestions, rarely commits;
Pair/Pilot/Auto = progressively more edit-committing. "Respond to fit what we're
doing" = a per-context agent swap, chosen by mode + work package.

**Same injection point as the journal:** the injected agent/system preamble carries
BOTH the output contract AND the journal context (§3.6/§3.12) — one place where
Tandem shapes how the model behaves and what it knows.

**Caveat:** marker reliability tracks model quality; the parser must degrade
gracefully (untagged → prose).

### 3.14 Interrupt/cancel & agent safety (must-have)

- **Cancel:** every running turn MUST be stoppable. `client.session.abort({path:
  {id}})`; daemon `cancel` command; bubble `<C-c>`. (This is hard-cancel — distinct
  from the mid-stream *interrupt-and-resume* of §3.2/§3.8, which is harder and comes
  later. Hard-cancel first.)
- **Agent safety:** OpenCode's default agent is `build` — fully agentic with edit
  and shell tools, so a stray sentence ("we're writing Tandem in Zig") can make it
  start *doing work* with no off switch. **The chat bubble defaults to the read-only
  `plan` agent** so plain conversation never edits files. Edit-capable agents
  (`build`) are opt-in via the autonomy dial (§3.4/§3.13): Coach/Pair = plan; Pilot/
  Auto = build. (Available agents incl. `build`, `plan`, `general`, `explore`.)
- **The autonomy dial = two levers**, and the motivating failure is an AI deciding
  on its own to do something big (e.g. "port Tandem to Zig") and just doing it:
  1. **agent selection** — `plan` (read-only) ↔ `build` (can edit);
  2. **decision/permission gating** — *even in build mode*, big moves hit a
     permission gate (OpenCode `permission.asked`): Tandem pauses, asks "it wants to
     edit `foo.zig` — approve / step through / no?", and on approval opens the file
     and walks the edits (§3.3, §3.11). The `plan` default is an **interim
     guardrail** until this gating + typewriter-on-edits exists.

### 3.10 Model routing & selection

Different jobs want different models — a cheap/fast one for coach observations, a
strong one for planning, the daily driver for general Q&A. Tandem needs:

- **per-role default models** (ask / coach / plan / edit), configurable;
- **live model switching mid-interaction**, like Claude Code / OpenCode (pick from
  a list, from a bubble command/picker);
- the choice surfaced *where you're working*, not buried in a config file.

With OpenCode as backend, available models come from `/api/model` + the user's
auth, and switching = setting the session/prompt model. Anthropic models are not
available via OpenCode (§4.4) and arrive only with the dedicated Anthropic backend.

### 3.11 Tool calls: visibility, gating, and the edit-application question

An agent doesn't only emit text — it calls tools (web search, run command,
read/edit files). Three levels of treatment, in increasing difficulty:

1. **Visibility (early, easy).** Tool activity streams on the *same* event channel
   as text. Surface it live in the bubble — "🔍 searching the web…", "📖 reading
   `foo.lua`", "✏️ editing `bar.lua`". Do this alongside text streaming.
2. **Gating (mid).** Approve / deny / edit a tool *before* it runs, via OpenCode's
   native `permission.asked` (§4.4). The popup shows the proposed call; you confirm
   or override. This is the tool-side of §3.3 decision-gating.
3. **Edit-application control (hard, later).** File-edit tools are special: this is
   where the typewriter belongs. But **OpenCode owns file writes**, so there's a
   real tension between "OpenCode applies the edit" and "Tandem controls *how* it's
   applied (granularity, interrupt, walk-through)". Two strategies:
   - **Intercept via permission** — gate the edit tool, read the proposed content
     from the permission request, suppress OpenCode's own write, and apply it
     ourselves through the typewriter. Full control, but depends on the proposed
     content being exposed and the native write being suppressible.
   - **Observe & replay** — let OpenCode write to disk, catch `EventFileEdited`,
     reload, and replay the change as a typewriter *animation* (§3.5). Simpler, but
     the edit is already applied — no true mid-write interrupt.
   This is the single biggest open question in marrying OpenCode-as-engine with the
   typewriter, and likely where Tandem eventually needs its own edit-application
   layer. Tackle only after streaming + visibility + gating work.

---

## 4. Architecture

Three thin layers; the model backend is swappable.

```
┌─────────────────────────────────────────────┐
│ Neovim plugin (Lua)                          │  ← all UX, the original part
│  • bubble (anchored float)                   │
│  • typewriter (queue drain, granularity)     │
│  • inbox window, planning popup              │
│  • event capture (buffer changes, cursor)    │
│  • autonomy dial                             │
└───────────────┬─────────────────────────────┘
                │  JSON over socket / HTTP (streaming)
┌───────────────▼─────────────────────────────┐
│ Sidecar process (TS or Python)               │  ← orchestration + state
│  • session/journal store                     │
│  • decision/breakpoint protocol              │
│  • Backend adapter interface                 │
└───────────────┬─────────────────────────────┘
                │  adapter
        ┌───────┴────────┐
┌───────▼──────┐  ┌──────▼─────────┐
│ OpenCode     │  │ Claude Agent   │   (swappable; more can be added)
│ server       │  │ SDK            │
└──────────────┘  └────────────────┘
```

### 4.1 Backend adapter interface

```
Backend = {
  send(context, messages) -> stream of events
  events: text_chunk | decision_request | tool_request | done | error
}
```

The Neovim layer never knows which backend is running. It just receives
`text_chunk` and `decision_request` events and renders them. Two adapters,
switchable per-session or per-keybind:

- **OpenCode server** (`opencode serve` + SDK) — **build this first**; the user
  already likes it, least new infra. (Verify current API surface.)
- **Claude Agent SDK** — second; its permission/confirmation hooks map cleanly to
  the gating model. Shared feature set = lowest common denominator; some advanced
  features may stay backend-specific at first.

### 4.2 Who owns the agentic loop?

The backend does (for now). The "agentic loop" = the cycle of *send context →
model replies / requests a tool → run tool → feed result back → repeat until
done*. OpenCode and Claude both ship their own. Tandem drives theirs and owns the
**experience** on top. Rebuilding the loop by hand (possibly in Zig) is a great
*later* learning phase — do not block the editor experience on it.

### 4.3 Neovim primer (for the builder)

- A **buffer** is Neovim's in-memory copy of a file; it exists whether or not it's
  shown in a window. The agent can edit any file regardless of what's on screen,
  then write it to disk.
- **Floating windows** (`nvim_open_win`, `relative='cursor'`) give anchored
  popups. A literal speech-bubble *tail* is fiddly in a character grid — approximate
  with a bordered float + a gutter sign / virtual-text caret pointing at the
  anchor line. Don't sink days into pixel-perfect tails.
- The typewriter uses a timer (`vim.loop`) + `nvim_buf_set_text` to drain the
  queue.
- Watch the user's typing via `nvim_buf_attach` / `TextChanged` (debounced) for
  coach mode.

### 4.4 OpenCode backend — concrete integration (verified 2026-06-23, oc 1.17.9)

Run `opencode serve --port 4096` → HTTP server at `http://127.0.0.1:4096`. It
ships an OpenAPI spec at `/doc`. **No separate sidecar needed for now** — the
OpenCode server *is* the engine; Neovim talks to it directly via `curl`
(`jobstart` for the SSE stream). Auth uses OpenCode's own `auth.json`, so no API
key.

Streaming flow:
1. `POST /api/session` (body `{}` or `{model:{providerID,id}}`) → `data.id`
   (a `ses_…`).
2. Subscribe `GET /api/event` — an SSE stream (`text/event-stream`), `data: {json}`
   lines. Events use dot-type names.
3. `POST /api/session/{id}/prompt` body `{"prompt":{"text":"…"}}` — returns
   immediately ("admitted"); output arrives on the event stream.
4. Read events: **`message.part.delta`** (`properties.delta.text` = the token
   chunk → append to bubble), `message.part.updated` (full snapshots),
   **`session.idle`** (done), `session.error` (failure).

**Native decision-gating (big — maps directly to §3.3):** OpenCode already emits
`question.asked` / `permission.asked` events and exposes
`POST /api/session/{id}/question/{rid}/reply|reject` and
`…/permission/{rid}/reply`. So we likely **render OpenCode's own questions/
permissions in the bubble** rather than building gating from scratch.

**Models via OpenCode:** `/api/model` surfaces only the OpenCode-hosted "zen"
models plus whatever the user's OpenCode auth enables; no default is set, which is
why a bare prompt produced nothing.
- `opencode/north-mini-code-free` (zen, free) — **works, $0** → use for the spike.
- The user's real OpenCode daily driver is an **OpenAI model (GPT-5.5)**; OpenRouter
  also available (needs credits).
- **Anthropic/Claude is NOT accessible through OpenCode** for this user — that is
  precisely why the **dedicated Anthropic backend adapter** (Claude Agent SDK,
  §4.1) exists as a separate future path, not something to fix inside OpenCode.
Model is swappable by design, so the spike uses zen-free and real models come via
per-role routing (§3.10).

**Two integration philosophies (learned from reading `opencode.nvim` source):**
- **TUI injection** (what `opencode.nvim` does): `POST /tui/publish`
  (`tui.prompt.append` then `tui.command.execute`/`prompt.submit`). Requires a
  running OpenCode **TUI** (headless no-ops silently); the reply renders *in the
  TUI*, not in Neovim. **Wrong for Tandem** — we want the reply in the bubble.
- **Headless programmatic prompt** (what Tandem needs): create session → `POST`
  prompt → stream the assistant text back over SSE. This is the right path, but
  the exact run-triggering call was not nailed by hand (raw `POST
  /api/session/{id}/prompt` *admitted* but produced no output in tests). The
  official **`@opencode-ai/sdk`** encapsulates the correct sequence — strong
  reason to run a tiny Node sidecar using the SDK rather than hand-rolling curl.

**Reusable transport pattern (from `opencode.nvim`):** subscribe to the SSE stream
with `curl -sN /event` via `vim.fn.jobstart`, accumulate `data:` lines into one
event per blank-line boundary, `json_decode`, dispatch under `vim.schedule`. The
same stream carries `permission.asked` / `file.edited` events (validates §3.11).
This means: **a thin sidecar after all** — the spike's "no sidecar" hope dies on
the headless prompt-trigger; reintroduce a minimal SDK-based sidecar.

**Sidecar — BUILT & WORKING (`tandem/sidecar/sidecar.mjs`).** Node + `@opencode-ai/sdk`.
`createOpencode({ port: 0 })` boots a server on a random port (port 0 is essential
— the SDK defaults to 4096 and orphaned servers otherwise collide → `ServeError`;
also must call `server.close()` on exit). Flow: `event.subscribe()` →
`session.create()` → `session.promptAsync({ path:{id}, body:{ model:{providerID,
modelID}, parts:[{type:"text",text}] } })` → iterate `events.stream`. Streamed text
arrives as `message.part.delta` events with `{ field:"text", delta:"…" }`.
Stdout protocol (one JSON/line): `{type:"session",id}` / `{type:"delta",text}` /
`{type:"done"}` / `{type:"error",error}`. Caveat: the free zen model leaks its
reasoning into the text deltas — filter by part type / use a better model later.

---

## 5. Risks / hard parts

- **Scope.** 4–5 real features. Without a ruthless MVP, burnout before the fun.
- **Annoyance gradient.** Confirm-everything becomes Clippy. The autonomy dial +
  "auto-approve safe, gate risky" trust levels are the mitigation.
- **Cost / latency.** Streaming everything + coach observation = many tokens.
  Throttle; make coach observation an explicit, bounded "observe until stop."
- **Two processes + a plugin** is real systems work. (For this user's goals, a
  feature, not a bug.)
- **Speech-bubble tail** is cosmetic and harder than it looks; ship the
  approximation.

---

## 6. Phased plan

- **Phase 0 — Spike: the typewriter.** Stream one edit from the raw API into a
  buffer with a speed/granularity dial and pause/resume. Proves the entire *feel*.
  Tiny. Do this first, before any backend abstraction.
- **Phase 1 — Bubble + context.** Anchored float; send line / visual selection /
  file as context; chat at location. First real "ask at the place" loop. Stand up
  the sidecar + OpenCode adapter here.
- **Phase 2 — Decisions + trust.** Breakpoint protocol; interactive (non-batch)
  gate in the bubble; trust dial (auto-approve safe, gate risky).
- **Phase 3 — Walk-through / explain.** Step through freshly written code or a
  diff, with Socratic prompts ("why do you think this is async?"), not just
  exposition.
- **Phase 4 — Coach / observe mode.** Bounded observation of the user's typing;
  non-intrusive suggestions; "you write this, I'll review."
- **Phase 5 — Planning popup + journal.** Central planning float (live-written
  plan); the append-only journal as memory + inbox + queryable history.
- **Later — own the loop.** Optionally rebuild the agentic loop by hand as a
  learning project.

Interrupt/resume and the autonomy dial thread through all phases; keep them
pragmatic (see §3.8).

### 6.1 Path to the headline feature (real-time file editing)

The core promise — **watch the AI edit files in real time at controllable
granularity, interrupt/correct/ask mid-edit, across files** — is the destination,
not yet built. Pieces and status:
- Typewriter w/ granularity + pause/resume — **BUILT** (week 1; runs on demo text,
  not real edits yet).
- Streaming, located bubble, sessions/memory, model selection — **BUILT**.
- **Gateway = §3.13 structured output** (NEXT): the model TAGS its edits (file +
  content) and decisions, so Tandem can intercept them instead of letting OpenCode
  silently write.
- **Headline = typewriter-on-edits (§3.11):** intercept a tagged edit (via
  permission), open the file, apply it through the *existing* typewriter. Hard part
  = OpenCode-owns-writes (intercept-via-permission vs observe-and-replay).
- Then: multi-file navigation, interrupt-and-resume (regenerate, §3.8), walk-through
  mode, decision/permission gating (§3.3) — all dialed by the autonomy level.

So §3.13 is **not a detour** — it is the unlock for file editing. The typewriter
(the real-time-modification engine) is already done; §3.13 + interception is what
finally feeds it real edits.

---

## 7. Open questions

- Project name.
- Sidecar language: TS (matches OpenCode/Agent SDK ecosystems) vs Python (cleanest
  Anthropic SDK) — lean TS for ecosystem fit unless there's a reason not to.
- How decision-span tagging is actually expressed by the model (structured
  sentinels in the stream vs a tool-call-shaped side channel) — prototype in
  Phase 2.
- How far the "replayable change" recording goes (full keystroke stream vs
  before/after + synthesized animation).

---

## 8. Glossary

- **Apply-stream** — the queue of generated edits the typewriter drains.
- **Breakpoint** — a tagged decision span that pauses the apply-stream.
- **Application-side pause** — pausing already-generated output you're stepping
  through.
- **Generation-side pause** — the model stopping because it needs an answer before
  it can produce more.
- **Autonomy dial / modes** — Coach / Pair / Pilot / Auto, live-adjustable.
- **Journal** — append-only record of intentions/decisions/changes; memory +
  inbox + queryable history.
- **Bubble** — the anchored floating popup for located interaction.
- **Inbox** — the floating command window listing outstanding actions/thoughts.
