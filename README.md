# Tandem

A Neovim AI pair-programming plugin that keeps **you in the loop**. Instead of an agent
that runs off and rewrites your files, Tandem pairs with you: it types edits in where you
can watch, pause, and take over; it asks before it acts; and it keeps a shared memory of
what you're working on. Swappable backends (OpenCode + Claude) mean you bring your own
model.

> **Status: early / experimental.** This started as a personal project and is developed
> against the author's setup. It works, but it's young — expect rough edges, and please
> open issues.

---

## Why

The idea is to remove the "I have to understand everything before I can start" barrier
*without* letting your skills atrophy from passive agent use. You stay the driver of your
own understanding: you see every change land, you make the decisions, and the work is
captured so you can pick it up again later.

## Features

- **Pairing roles.** Be the **Navigator** (the AI guides, *you* write — its code arrives
  as ghost text you choose to accept) or let the AI **Drive** (it writes, you watch it
  type in and can interrupt). Plus a **Neutral** "just help" mode and a **Coach** toggle.
- **Watchable edits.** The AI's writes are typed into your buffer with a highlighted
  region and an animated `Implementing…` marker — pause/resume the typing, or interrupt to
  take over, then tell it to continue with your changes folded in.
- **Workpackages, sessions, journal & backlog.** Organise work into named workpackages,
  each with many conversation sessions, a shared **journal** (a living brief the AI keeps
  current) and a **backlog** — all stored per-project in `.tandem/`.
- **Bring your own model.** Model lists are pulled live from the backends (every OpenCode
  provider + your Claude models), with a per-model **reasoning effort** dial.
- **Tool-call visibility.** Watch tool calls and their output stream in a toggleable
  activity bar, and see the full session — reply text, tool calls, questions — woven into
  the main chat transcript.
- **Permission gate.** Side-effecting tools (`bash`, `webfetch`) ask before they run
  (allow once / always / reject).

## Requirements

- **Neovim ≥ 0.10**
- **Node.js ≥ 18** (runs the sidecar that talks to the model backends)
- **At least one backend:**
  - **OpenCode** — configured and authenticated (a provider/model available), and/or
  - **Claude** — [Claude Code](https://claude.com/claude-code) installed and logged in (a
    Pro/Max subscription works; no API key needed)
- *Optional:* [`render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim)
  + `nvim-treesitter` (with the `markdown` parser) for richer chat rendering.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "cjrsmith/tandem",
  -- installs the sidecar's Node dependencies on install/update
  build = "npm install --prefix sidecar",
  dependencies = {
    -- optional, for rich markdown in chat windows
    "MeanderingProgrammer/render-markdown.nvim",
  },
  config = function()
    require("tandem").setup({})
  end,
}
```

The `build` step runs `npm install` in the plugin's `sidecar/` directory. If you skip it,
run it manually once:

```sh
npm install --prefix ~/.local/share/nvim/lazy/tandem/sidecar
```

## Quick start

1. Open Neovim **in your project root** (Tandem stores per-project state relative to your
   current working directory).
2. Press **`<leader>tt`** to open the main chat (the command centre), or **`<leader>tc`**
   for a bubble at your cursor.
3. Ask for something. In **Driver** mode it types the change into your buffer; in
   **Navigator** mode it offers code you can ghost (`<leader>ti`) and accept (`<leader>ta`).
4. Switch modes, models, and everything else from the settings menu: **`<leader>t<Space>`**.

## Keymaps

Tandem installs a default keymap set on the **`<leader>t`** prefix. Only frequent, in-flow
actions get a direct key; everything else lives behind the settings menu
(`<leader>t<Space>`).

| Group | Keys |
|---|---|
| **Chat** | `tt` main chat · `tc` bubble · `te` ephemeral · `tk` fork · `tf` about file · `tp` reopen previous *(c/e/k also work in visual mode → about the selection)* |
| **Suggestions** | `ti` ghost · `ta` accept · `td` dismiss |
| **Driver flow** | `tg` jump to edit · `tw` confirm Follow write · `tx` interrupt · `tr` continue · `t=` pause typing · `t-` resume · `tG` clear highlight · `t/` cancel all |
| **Review changes** | `tv` review · `tV` exit · `tS` summarise |
| **Context** | `ts` switch session · `tn` new session · `tj` journal · `tb` backlog · `tm` model · `tP` capture plan · `t]` next instruction |
| **Visibility** | `to` toggle tool activity bar · `<C-Space>` toggle focus |
| **Hub** | `t<Space>` settings menu · `tQ` close surfaces · `tq` dismiss toast |

Change the prefix or opt out entirely (see [Configuration](#configuration)).

## Concepts

**Modes & levels.** *Navigator* (you write; the AI guides) has a **guidance** level;
*Driver* (the AI writes) has an **autonomy** level; both scale High/Medium/Low. *Coach* is
a Socratic toggle over either. *Neutral* is a plain assistant. Pick the mode and you're
prompted for its level; change either any time from the settings menu.

**Workpackages & sessions.** A **workpackage** is a named container for a chunk of work —
it owns a shared journal + backlog and holds **many sessions** (conversation threads).
Switching = picking a session (shown as `workpackage ▸ session`). New workpackages/sessions
are created on demand; if you never make one you get a `default`. All of this lives in
`.tandem/` in your project.

**Journal & backlog.** The **journal** is a concise, always-current brief (goal, state,
decisions, approach) that's injected into every session — the AI keeps it up to date as
decisions land, and you can jot in it too. The **backlog** is a per-workpackage task list.
Both are plain markdown you can edit.

**Models & effort.** `<leader>tm` lists the models available through your backends; picking
a Claude model switches the backend to Claude. Reasoning-capable models then prompt for an
**effort** level (`minimal`/`low`/`medium`/`high`), applied per turn.

**Permissions & visibility.** `bash`/`webfetch` ask before running. A toggleable activity
bar (`<leader>to`) shows tool calls and their output live, and the main chat transcript
captures the full session (reply text + tool calls + questions), so it's a source of truth
for what happened.

## Configuration

`setup()` takes:

```lua
require("tandem").setup({
  -- keys = false,          -- don't install any default keymaps (bind your own)
  -- prefix = "<leader>a",  -- move the whole default keymap set to another prefix
})
```

That's the whole surface today — most behaviour is driven at runtime from the settings menu
and rail rather than static config.

## How it works

Neovim (Lua) drives the UX; a persistent **Node sidecar** (`sidecar/daemon.mjs`) boots a
model backend and streams events back over stdin/stdout. Two backends are supported behind
one protocol:

- **OpenCode** via `@opencode-ai/sdk`
- **Claude** via `@anthropic-ai/claude-agent-sdk` (spawns the `claude` binary, so it uses
  your Claude Code login)

The AI's file writes, questions, and status all come back as structured events that Tandem
turns into the typewriter, ghost text, toasts, and activity views. The agent personas live
in `agents/*.md` and are injected per turn.

## License

MIT — see [`LICENSE`](LICENSE).
