# Tandem Walkthrough Plan

## Goal

Build a Walkthrough feature for Tandem that guides the user through existing code directly in Neovim. The user should be able to start a walkthrough for the current file or a visual selection, then move through AI-generated semantic stops. Each stop jumps to the relevant code and shows a concise floating explanation bubble anchored to the buffer location.

The feature should feel like someone sitting next to the user and saying: "this block does X; now jump here and you can see where it is called; now jump here and this is where that value is defined."

## Product Shape

- Walkthrough is a navigable overlay on top of the editable buffer.
- Walkthrough does not create a separate conversation mode.
- Clarifying questions and code changes use existing Tandem chat, selection, file, and edit flows.
- Code remains editable during walkthrough.
- Walkthrough locations should track edits as well as possible using extmarks.
- The model chooses semantic stops, not one explanation per line.
- The UI should reuse the review-mode mental model: quickfix navigation plus a floating explanation bubble.

## User-Facing Commands

Add commands roughly equivalent to:

```vim
:TandemWalkthrough
:TandemWalkthroughSelection
:TandemWalkthroughNext
:TandemWalkthroughPrev
:TandemWalkthroughRegenerate
:TandemWalkthroughExit
```

Possible keymaps under the existing Tandem prefix need final collision checks before implementation. Candidate behavior:

- Normal mode start: walkthrough current file.
- Visual mode start: walkthrough selected range.
- Next: jump to next walkthrough stop.
- Previous: jump to previous walkthrough stop.
- Regenerate: rebuild stops from current live file/range.
- Exit: clear walkthrough UI/state.

## Core Data Model

Add dedicated walkthrough state near review-mode state in `lua/tandem/init.lua`.

Suggested fields:

```lua
M._walkthrough_active = false
M._walkthrough_steps = nil
M._walkthrough_index = 1
M._walkthrough_cache = M._walkthrough_cache or {}
M._walkthrough_source = nil
```

Each step should be normalized into something like:

```lua
{
  file = "/absolute/path/to/file.lua",
  start_line = 120,
  end_line = 148,
  title = "Region selection is captured",
  explanation = "This block records the selected range using extmarks...",
  top_mark = 1,
  bot_mark = 2,
  hash = "..."
}
```

Important distinction:

- `start_line` and `end_line` are the original model-provided lines.
- `top_mark` and `bot_mark` are the live Neovim extmarks used for navigation after edits.

## Namespace

Create a dedicated namespace:

```lua
local walkthrough_ns = vim.api.nvim_create_namespace("tandem_walkthrough")
```

Use this namespace for all walkthrough extmarks and any future highlighting. This keeps walkthrough independent from edit, region, chat, rail, and review namespaces.

## Input Capture

### Current File

For file walkthrough:

- Require a valid named buffer.
- Capture absolute file path.
- Capture filetype.
- Capture all buffer lines.
- Format content with stable 1-indexed line numbers.
- Compute a content hash for cache lookup.

### Visual Selection

For selection walkthrough:

- Capture selected start/end positions.
- Normalize range order.
- Include absolute file path and filetype.
- Include only selected lines, but preserve real file line numbers.
- Store source-range extmarks so regenerate can use the live range later.
- Compute a hash from file path, selected line range, and selected text.

## Prompt Contract

Use the existing `M.prompt(...)` flow, similar to `review_summaries()`.

The model should receive line-numbered code and return strict JSON only:

```json
{
  "steps": [
    {
      "start_line": 10,
      "end_line": 24,
      "title": "What this block does",
      "explanation": "Concise explanation grounded in this block."
    }
  ]
}
```

Prompt requirements:

- Return valid JSON and nothing else.
- Use only line numbers that exist in the provided code.
- Prefer semantic blocks over individual lines.
- Do not explain every trivial statement.
- Cover important execution flow, data flow, definitions, call sites, state transitions, side effects, and non-obvious logic.
- For a full file, target roughly 6-14 stops unless the file is very small.
- For a selection, target roughly 3-10 stops unless the selection is very small.
- Keep titles short.
- Keep explanations concise enough for a floating bubble.
- Ground explanations only in the provided code.

## Parsing And Validation

When model output completes:

1. Accumulate streamed text.
2. Trim whitespace.
3. Decode as JSON with `vim.json.decode`.
4. Verify top-level object has a `steps` array.
5. For each step:
   - Coerce line numbers to integers.
   - Clamp or reject lines outside the source range.
   - Ensure `start_line <= end_line`.
   - Require non-empty title and explanation.
   - Drop malformed steps.
6. Sort by `start_line`, then `end_line`.
7. Optionally drop exact duplicates.
8. If no valid steps remain, notify and do not enter walkthrough mode.

Prefer rejecting clearly invalid steps over trying to guess what the model meant.

## Extmark Creation

For each validated step:

- Load or show the target buffer.
- Convert 1-indexed model lines to 0-indexed extmark rows.
- Create a top extmark at `start_line - 1`, column `0`, with `right_gravity = false`.
- Create a bottom extmark at `end_line - 1`, end-of-line column, with `right_gravity = true`.

The walkthrough should navigate by resolving extmarks live, not by reusing stale `start_line` values.

If a mark is lost later, the step can be skipped or reported as unavailable.

## Quickfix Integration

Populate quickfix with one item per walkthrough stop:

```lua
{
  filename = step.file,
  lnum = live_start_line,
  text = string.format("%d/%d %s", i, total, step.title)
}
```

Set the quickfix title to `Tandem walkthrough`.

Open quickfix and jump to the first stop when a walkthrough starts.

Quickfix provides:

- A visible list of stops.
- Familiar `:cnext` / `:cprev` behavior.
- A simple way to inspect the generated structure.

Dedicated next/previous functions should still exist so Tandem can keep its own index and bubble behavior consistent.

## Navigation

Implement helpers:

```lua
M.walkthrough_next()
M.walkthrough_prev()
M.walkthrough_jump(index)
```

`walkthrough_jump(index)` should:

1. Validate active state.
2. Resolve the step's live top extmark position.
3. Show the relevant buffer in a normal window.
4. Move cursor to the live start line.
5. Center with `normal! zz`.
6. Update `M._walkthrough_index`.
7. Show the explanation bubble.
8. Optionally sync quickfix selection if practical.

Next/previous should wrap or stop at boundaries. Prefer stopping at boundaries initially, with a small notification like `Tandem walkthrough: last stop`.

## Bubble Rendering

Reuse the review bubble pattern from `M.review_show_summary()`.

Bubble content:

```text
Walkthrough 3/9: Step title

Explanation text...
```

Behavior:

- Non-focusable.
- Anchored near cursor.
- Rounded border.
- Wrapped text.
- Width clamped to a readable maximum.
- Height derived from wrapped lines.
- Replaced when moving to a different step.
- Closed on exit.

Consider extracting common float-sizing logic later if review and walkthrough duplicate too much code, but do not over-refactor initially.

## Cursor-Move Sync

Create a `TandemWalkthrough` augroup while active.

On `CursorMoved`:

- If the current buffer and cursor line fall inside a walkthrough step's live extmark range, show that step's bubble.
- Update `M._walkthrough_index` to that step.
- If outside all steps, either keep the last bubble or close it.

Recommended initial behavior: close the bubble when outside all steps, because it avoids stale explanations while manually browsing.

## Editing During Walkthrough

Walkthrough must not lock buffers.

Expected behavior while editing:

- Edits above a stop should move the extmarks and navigation should still work.
- Edits inside a stop should keep the bubble associated with the edited region where possible.
- Existing Tandem edit tools should work normally.
- If enough code changes that the explanation becomes stale, the user can run regenerate.

Do not add automatic regeneration initially. It may be expensive and surprising.

## Regenerate

Implement:

```lua
M.walkthrough_regenerate()
```

Behavior:

- If no walkthrough is active, notify the user.
- If source is file, recapture the whole current file and rebuild stops.
- If source is selection, resolve stored source-range extmarks, recapture that live range, and rebuild stops.
- Clear old walkthrough extmarks and bubble before replacing state.
- Bypass cache.
- Start again at the first generated stop.

## Cache

Add a simple content-hash cache:

```lua
M._walkthrough_cache[hash] = parsed_steps
```

Cache key should include:

- Mode: file or selection.
- File path.
- Source range for selection.
- Source text hash.

Normal walkthrough start can reuse cache if available. Regenerate should bypass and replace cache.

Cached steps still need fresh extmarks because buffers may have changed.

## Exit And Cleanup

Implement:

```lua
M.walkthrough_exit()
```

Cleanup responsibilities:

- Set active state false.
- Clear `M._walkthrough_steps`.
- Reset index/source.
- Close walkthrough bubble.
- Clear `walkthrough_ns` extmarks from relevant buffers.
- Delete `TandemWalkthrough` autocmd group.
- Close quickfix if its title is `Tandem walkthrough`.
- Notify the user.

Be careful not to clear unrelated quickfix lists if the user changed quickfix after starting walkthrough.

## Commands And Keymaps

Add commands during setup or module load, following existing style.

Before choosing default keymaps, check current bindings around lines where `M.setup_keymaps` maps review and navigation keys.

Avoid collisions with:

- Review mode.
- Existing instruction navigation.
- Chat/file/selection commands.
- Suggestion/edit flow commands.

If clean mnemonic keys are unavailable, commands alone are acceptable until keymap design is finalized.

## Error Handling

Handle these cases cleanly:

- Unnamed buffer.
- Empty buffer or empty selection.
- Model returns malformed JSON.
- Model returns no valid steps.
- Step points outside source range.
- Buffer was closed before generation completed.
- Extmark disappeared before navigation.
- User exits while generation is in flight.

Notifications should be short and specific.

## Manual Verification Checklist

Run through these in Neovim:

- Start walkthrough for current file.
- Start walkthrough for visual selection.
- Move next and previous through stops.
- Use quickfix to jump between stops.
- Confirm bubble updates for each stop.
- Move cursor manually into a stop and confirm bubble appears.
- Move cursor outside stops and confirm bubble closes or does not become misleading.
- Edit above a stop, then navigate back to it.
- Edit inside a stop, then navigate away and back.
- Ask a normal Tandem question about the visible block.
- Make a normal Tandem edit during walkthrough.
- Regenerate after edits.
- Exit and confirm bubble/extmarks/autocmds/quickfix are cleaned up.
- Try unnamed buffer and confirm friendly failure.
- Simulate malformed model output if practical and confirm friendly failure.

## Implementation Sequence

1. Add walkthrough namespace and state.
2. Add bubble close/show helpers.
3. Add source capture for file and visual selection.
4. Add prompt construction and model call.
5. Add JSON parsing and validation.
6. Add extmark anchoring.
7. Add quickfix population.
8. Add jump/next/previous behavior.
9. Add cursor-move sync.
10. Add regenerate.
11. Add exit cleanup.
12. Add commands and keymaps.
13. Run manual verification and tune the prompt.

## Non-Goals For Initial Build

- Dedicated ask-about-current-step command.
- Separate walkthrough conversation state.
- Automatic regeneration after every edit.
- Codebase-wide multi-file walkthrough planning via a dedicated backend tool.
- Heavy refactoring of review mode.

These can be revisited after the single-file/selection walkthrough feels solid.
