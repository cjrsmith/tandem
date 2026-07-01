# Loupe — Project Journal

The durable, human-readable context Loupe injects so the model always knows what
we're doing. (Minimal version: read-only, injected on a session's first turn.
Later: Loupe appends decisions here automatically.)

## What we're building
Loupe — a Neovim plugin that keeps the human in the loop and learning while using
AI: a located, streaming chat bubble anchored at the code, backed by OpenCode.
Philosophy and full spec live in DESIGN.md.

## Current focus
The memory milestone: persistent OpenCode daemon (done) + the work-package /
session / journal abstraction so the bubble remembers what we're working on.

## Key decisions
- Backend = OpenCode via a persistent Node sidecar (`sidecar/daemon.mjs`); model
  swappable. Anthropic gets a separate backend later.
- Spike model = `opencode/north-mini-code-free` (free; leaks reasoning).
- Rule: regenerate, don't reconcile, when the human changes mid-stream.
- Routing depends on a structured output contract from an injected agent/skill.

## 2026-06-24 12:40
Decided: bubbles share one active working session, reset with <leader>ln.
