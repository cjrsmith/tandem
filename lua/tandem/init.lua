local M = {}

local ns = vim.api.nvim_create_namespace("tandem")
local edit_ns = vim.api.nvim_create_namespace("tandem_edit") -- the "AI is writing here" highlight
-- Region markers live in their OWN namespace so a running typewriter's clear_edit
-- (which wipes edit_ns) can't erase a still-PENDING region's marks. This is what lets
-- several region requests be armed at once (select A, ask; select B, ask; …).
local region_ns = vim.api.nvim_create_namespace("tandem_region")

-- Diff-style highlight over the region the AI is actively typing into. `default`
-- so a user colourscheme can override it.
-- Subtle blue/grey wash over the region the AI is writing.
vim.api.nvim_set_hl(0, "TandemActiveEdit", { bg = "#2d3446" })
vim.api.nvim_set_hl(0, "TandemImplementing", { link = "Comment", default = true })
local IMPL_LABEL = "⟨ implementing… ⟩" -- the marker shown above & below the AI's region

local chat_ns = vim.api.nvim_create_namespace("tandem_chat") -- user-message backgrounds
-- Subtle grey block behind YOUR messages in chat (like opencode/claude); overridable.
vim.api.nvim_set_hl(0, "TandemUserMsg", { bg = "#2b2b33", default = true })

-- Mark a window as a Tandem surface (chat bubble / ask / instruction / command centre)
-- so M.toggle_focus can cycle between them and your code without closing anything.
local function mark_surface(win)
	pcall(vim.api.nvim_win_set_var, win, "tandem_surface", true)
end
local function is_surface(win)
	local ok, v = pcall(vim.api.nvim_win_get_var, win, "tandem_surface")
	return ok and v == true
end
-- Shared border highlights so bubbles and the command centre look the same.
vim.api.nvim_set_hl(0, "TandemBorderActive", { link = "Function", default = true })
vim.api.nvim_set_hl(0, "TandemBorderDim", { link = "Comment", default = true })

-- Render a buffer's content as markdown (highlighting + inline conceal), the way
-- replies look in opencode / claude. Treesitter when available, else built-in syntax.
local function style_markdown(buf, win)
	vim.bo[buf].filetype = "markdown"
	pcall(vim.treesitter.start, buf, "markdown") -- base highlighting / fallback
	-- If the user runs render-markdown.nvim, give Tandem's floats the SAME rich render
	-- as opencode/claude (styled headings, bullets, code-block backgrounds, concealed
	-- markers). Setting ft fires FileType so the plugin normally auto-attaches, but a
	-- lazy-loaded plugin can miss a float that isn't the current buffer — so attach this
	-- buffer explicitly. pcall keeps us safe if the plugin is absent or its API shifts.
	pcall(function()
		local mgr = require("render-markdown.core.manager")
		mgr.attach(buf)
		mgr.set_buf(buf, true)
	end)
	if win and vim.api.nvim_win_is_valid(win) then
		vim.wo[win].wrap = true
		vim.wo[win].linebreak = true
		vim.wo[win].conceallevel = 2
		vim.wo[win].concealcursor = "nvic"
	end
end

M.active_session = nil -- the current working session, shared across bubbles
M.active_edit = nil -- { buf, srow, erow } — where the AI is currently writing code

-- Available models for the picker; M.active_model is what new prompts use. Each
-- model names its `backend` — the daemon routes on it (opencode vs the Claude
-- Agent SDK). Selecting a Claude model IS how you switch backends; the rail shows
-- the active one. Claude models need ANTHROPIC_API_KEY in the daemon's env.
M.models = {
	{ label = "GPT-5.5", backend = "opencode", providerID = "openai", modelID = "gpt-5.5" },
	{ label = "GPT-5.5 fast", backend = "opencode", providerID = "openai", modelID = "gpt-5.5-fast" },
	{ label = "GPT-5.4 mini", backend = "opencode", providerID = "openai", modelID = "gpt-5.4-mini" },
	{ label = "zen free", backend = "opencode", providerID = "opencode", modelID = "north-mini-code-free" },
	{ label = "Claude Opus 4.8", backend = "claude", providerID = "anthropic", modelID = "claude-opus-4-8" },
	{ label = "Claude Sonnet 4.6", backend = "claude", providerID = "anthropic", modelID = "claude-sonnet-4-6" },
	{ label = "Claude Haiku 4.5", backend = "claude", providerID = "anthropic", modelID = "claude-haiku-4-5-20251001" },
}
M.active_model = M.models[1] -- default: GPT-5.5 (clean output, follows instructions)

-- The active backend, derived from the selected model (defaults to opencode).
function M.backend()
	return (M.active_model and M.active_model.backend) or "opencode"
end

-- Pick the active model; subsequent prompts use it. Crossing backends is allowed
-- (it just means the next session runs on the other backend).
function M.pick_model()
	vim.ui.select(M.models, {
		prompt = "Tandem model:",
		format_item = function(m)
			return m.label .. "  (" .. (m.backend or "opencode") .. ")"
		end,
	}, function(choice)
		if choice then
			local switched = M.backend() ~= choice.backend
			M.active_model = choice
			if switched then
				-- backend is bound to the session (ids can't cross-resume) → move to a
				-- session on the new backend in this workpackage (reuse or create).
				pcall(M.switch_backend, choice.backend)
			end
			vim.notify("Tandem model → " .. choice.label .. (switched and ("  [" .. choice.backend .. "]") or ""))
			M.rail_refresh()
		end
	end)
end


M.granularity = "word" -- char | word | line | paragraph — pace for typed-in edits

-- Pick how fast typed-in edits land (the granularity dial).
function M.pick_granularity()
	vim.ui.select({ "char", "word", "line", "paragraph" }, {
		prompt = "Tandem typing granularity:",
	}, function(choice)
		if choice then
			M.granularity = choice
			vim.notify("Tandem granularity → " .. choice)
			M.rail_refresh()
		end
	end)
end

-- (M.new_session lives with the workpackage/session code below — it adds a fresh
-- session to the ACTIVE workpackage.)

-- Default keymaps. Only the IN-FLOW actions get a direct key; everything else (mode,
-- level, coach, follow, pace, session/workpackage rename, compact, jot note, plan,
-- restart daemon…) lives behind the settings menu at <prefix><Space>. Disable with
-- setup({ keys = false }); rebind the whole set with setup({ prefix = "<leader>a" }).
function M.setup_keymaps(prefix)
	prefix = prefix or "<leader>t"
	local function map(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, { desc = "Tandem: " .. desc, silent = true })
	end
	local function p(k)
		return prefix .. k
	end
	-- chat surfaces
	map("n", p("t"), M.open_chat, "main chat (command centre)")
	map("n", p("c"), function() M.chat_here() end, "chat bubble here")
	map("n", p("e"), function() M.chat_here("ephemeral") end, "ephemeral bubble")
	map("n", p("k"), function() M.chat_here("fork") end, "fork bubble")
	map("n", p("f"), function() M.chat_here("working", "file") end, "chat about whole file")
	map("n", p("p"), M.reopen_chat, "reopen previous bubble")
	map("x", p("c"), function() M.chat_here("working", "selection") end, "chat about selection")
	map("x", p("e"), function() M.chat_here("ephemeral", "selection") end, "ephemeral (selection)")
	map("x", p("k"), function() M.chat_here("fork", "selection") end, "fork (selection)")
	-- suggestions (Navigator ghosts)
	map("n", p("i"), M.ghost_suggestion, "ghost the suggestion")
	map("n", p("a"), M.accept_suggestion, "accept suggestion")
	map("n", p("d"), M.clear_suggestion, "dismiss ghost")
	-- Driver edit flow
	map("n", p("g"), M.jump_to_edit, "jump to the AI's edit")
	map("n", p("w"), M.confirm_write, "confirm Follow write")
	map("n", p("x"), M.interrupt_edit, "interrupt the turn (take over)")
	map("n", p("r"), M.continue_work, "continue the turn")
	map("n", p("="), M.pause, "pause typing")
	map("n", p("-"), M.resume, "resume typing")
	map("n", p("G"), M.clear_edit, "clear edit highlight")
	map("n", p("/"), M.cancel_all, "cancel everything")
	-- review the AI's uncommitted changes
	map("n", p("v"), M.review, "review changes")
	map("n", p("V"), M.review_exit, "exit review")
	map("n", p("S"), M.review_summaries, "summarise changes")
	-- context (frequent)
	map("n", p("s"), M.session_pick, "switch session")
	map("n", p("n"), M.new_session, "new session")
	map("n", p("j"), M.view_journal, "view journal")
	map("n", p("b"), M.backlog, "open backlog")
	map("n", p("m"), M.pick_model, "pick model")
	map("n", p("P"), M.capture_plan, "capture plan → journal + backlog")
	map("n", p("]"), M.next_instruction, "next instruction (Navigator)")
	-- surfaces / hub
	map("n", p("<Space>"), M.settings_menu, "settings menu")
	map("n", p("Q"), M.close_surfaces, "close all chat surfaces")
	map("n", p("q"), M.toast_dismiss, "dismiss toast")
	map({ "n", "i" }, "<C-Space>", M.toggle_focus, "toggle focus")
end

function M.setup(opts)
	M.opts = opts or {}
	pcall(M.wp_load) -- adopt the active workpackage's session on startup
	if M.opts.keys ~= false then -- setup({ keys = false }) to bind your own
		pcall(M.setup_keymaps, M.opts.prefix)
	end
end

M.last_suggestion = nil -- the chosen suggestion (code + where it belongs) to ghost/accept
M.candidates = nil -- { blocks = {code,…}, buf, row } — Navigator's offered code blocks

-- Every fenced ``` code block in a reply. Navigator suggestions live as ordinary
-- markdown code blocks in prose (the model fences reliably in conversation), so
-- these become candidates you can ghost — you pick which, so over-capture is cheap.
function M.extract_blocks(text)
	local blocks = {}
	for block in text:gmatch("```%w*\n(.-)\n```") do
		block = vim.trim(block)
		if block ~= "" then
			blocks[#blocks + 1] = block
		end
	end
	return blocks
end

-- Paint `code` as greyed ghost text below `row` in `buf`, and remember it as the
-- chosen suggestion (so <leader>la can type it in).
local function render_ghost(code, buf, row)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	M.last_suggestion = { code = code, buf = buf, row = row }
	local virt = {}
	for _, line in ipairs(vim.split(code, "\n", { plain = true })) do
		virt[#virt + 1] = { { line, "Comment" } }
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) -- replace any previous ghost
	vim.api.nvim_buf_set_extmark(buf, ns, math.max(0, row - 1), 0, { virt_lines = virt })
end

-- Ghost a suggestion at its origin. If the Navigator offered several code blocks,
-- pick which one; a single block ghosts directly.
function M.ghost_suggestion()
	local c = M.candidates
	if c and #c.blocks > 0 then
		if #c.blocks == 1 then
			render_ghost(c.blocks[1], c.buf, c.row)
		else
			vim.ui.select(c.blocks, {
				prompt = "Ghost which suggestion?",
				format_item = function(b)
					return (vim.split(b, "\n", { plain = true })[1] or b):sub(1, 50)
				end,
			}, function(choice)
				if choice then
					render_ghost(choice, c.buf, c.row)
				end
			end)
		end
		return
	end
	if M.last_suggestion then
		render_ghost(M.last_suggestion.code, M.last_suggestion.buf, M.last_suggestion.row)
		return
	end
	vim.notify("Tandem: no suggestion")
end

-- Dismiss the ghosted suggestion.
function M.clear_suggestion()
	if M.last_suggestion then
		vim.api.nvim_buf_clear_namespace(M.last_suggestion.buf, ns, 0, -1)
	end
end

-- "Accept" the last suggestion: TYPE it into the buffer at its origin via the
-- typewriter — so you watch it land and can pause/resume/interrupt mid-edit.
-- This is the first real typewriter-on-edits (§3.11).
function M.accept_suggestion(opts)
	local s = M.last_suggestion
	if not s then
		vim.notify("Tandem: no suggestion")
		return
	end
	M.clear_suggestion() -- remove the ghost preview
	local origin_line = vim.api.nvim_buf_get_lines(s.buf, s.row - 1, s.row, false)[1] or ""
	local gran = (opts and opts.granularity) or M.granularity
	local intervals = { char = 38, word = 75, line = 120, paragraph = 250 }
	-- type it onto new lines just below the origin line, at the chosen granularity
	M.type_out("\n" .. s.code, {
		buf = s.buf,
		row = s.row - 1, -- 0-indexed origin line
		col = #origin_line, -- end of that line
		granularity = gran,
		interval = (opts and opts.interval) or intervals[gran] or 30,
	})
end

-- State for an in-progress typing session. The AI's region is bounded by two
-- extmarks: `top_mark` (left gravity — stays above) and `bot_mark` (right gravity —
-- rides down as text is inserted). We always insert at the bottom mark's CURRENT
-- position, so the typewriter tracks any edits you make above it while it works.
local stream = {
	timer = nil, -- running timer handle, or nil when idle/paused
	chunks = {}, -- the generated text, split into chunks
	idx = 0, -- how many chunks we've applied so far
	buf = nil, -- buffer we're typing into
	top_mark = nil, -- extmark id at the region top
	bot_mark = nil, -- extmark id at the insertion point (region bottom)
	interval = 80, -- ms per chunk
}

-- 0-indexed position of an extmark in a given namespace, or nil if it's gone.
local function mark_pos_ns(buf, mns, id)
	if not id then
		return nil
	end
	local p = vim.api.nvim_buf_get_extmark_by_id(buf, mns, id, {})
	if #p == 0 then
		return nil
	end
	return p[1], p[2]
end
-- Position of an edit_ns mark (the typewriter's own marks).
local function mark_pos(buf, id)
	return mark_pos_ns(buf, edit_ns, id)
end

-- Refresh the region's highlight (top→bottom) + the cached active-edit bounds.
local function mark_refresh()
	if not (stream.buf and vim.api.nvim_buf_is_valid(stream.buf)) then
		return
	end
	local tr, tc = mark_pos(stream.buf, stream.top_mark)
	local br = mark_pos(stream.buf, stream.bot_mark)
	if not tr or not br then
		return
	end
	-- re-set the top mark in place, extending its highlight down to the bottom mark
	pcall(vim.api.nvim_buf_set_extmark, stream.buf, edit_ns, tr, tc, {
		id = stream.top_mark,
		right_gravity = false,
		virt_lines_above = true,
		virt_lines = { { { IMPL_LABEL, "TandemImplementing" } } },
		end_row = br,
		end_col = 0,
		hl_group = "TandemActiveEdit",
		hl_eol = true,
	})
	M.active_edit = { buf = stream.buf, top = stream.top_mark, bot = stream.bot_mark, srow = tr, erow = br }
end

-- Apply the next chunk at the bottom mark's current position; the mark rides down.
local function tick()
	if stream.idx >= #stream.chunks or not vim.api.nvim_buf_is_valid(stream.buf) then
		M.pause() -- queue drained or buffer gone: stop the timer
		local cb = stream.on_done
		stream.on_done = nil
		M.clear_edit() -- the edit is done: remove the ⟨implementing⟩ markers
		if cb then
			cb() -- fire once when the typewriter finishes (used to ack agent edits)
		end
		return
	end
	local row, col = mark_pos(stream.buf, stream.bot_mark)
	if not row then -- region was removed (e.g. buffer cleared) — stop
		M.pause()
		return
	end
	stream.idx = stream.idx + 1
	local repl = vim.split(stream.chunks[stream.idx], "\n", { plain = true })
	-- empty range = INSERT at the bottom mark; right-gravity makes it ride to the end
	vim.api.nvim_buf_set_text(stream.buf, row, col, row, col, repl)
	mark_refresh() -- keep the region highlight + bounds tracking
end

local function start_timer()
	stream.timer = vim.fn.timer_start(stream.interval, tick, { ["repeat"] = -1 })
end

local function chunk(text, granularity)
	local chunks = {}
	if granularity == "char" then
		for i = 1, #text do
			chunks[i] = text:sub(i, i)
		end
	elseif granularity == "line" then
		-- each chunk = one line *including* its trailing newline
		local start = 1
		while start <= #text do
			local nl = text:find("\n", start, true) -- plain (non-regex) find
			if nl then
				table.insert(chunks, text:sub(start, nl)) -- include the \n
				start = nl + 1
			else
				table.insert(chunks, text:sub(start)) -- final line, no \n
				break
			end
		end
	elseif granularity == "word" then
		-- alternating runs of non-space / space (lossless, keeps indentation)
		local i, n = 1, #text
		while i <= n do
			local is_space = text:sub(i, i):match("%s") ~= nil
			local j = i
			while j <= n and (text:sub(j, j):match("%s") ~= nil) == is_space do
				j = j + 1
			end
			table.insert(chunks, text:sub(i, j - 1))
			i = j
		end
	elseif granularity == "paragraph" then
		-- whole blocks, split at blank lines (a run of 2+ newlines); lossless
		local start = 1
		while start <= #text do
			local sfound, efound = text:find("\n\n+", start)
			if sfound then
				table.insert(chunks, text:sub(start, efound)) -- include the blank line(s)
				start = efound + 1
			else
				table.insert(chunks, text:sub(start))
				break
			end
		end
	end
	return chunks
end

-- Begin typing `text` into a buffer, one chunk per tick, inside a marked region.
function M.type_out(text, opts)
	opts = opts or {}
	M.pause()
	M.clear_edit() -- drop any previous region (possibly in another buffer)
	stream.interval = opts.interval or 80
	stream.buf = opts.buf or vim.api.nvim_get_current_buf()
	local cur = vim.api.nvim_win_get_cursor(0)
	local row = opts.row or (cur[1] - 1) -- 0-indexed row
	local col = opts.col or cur[2]
	stream.chunks = chunk(text, opts.granularity or "char")
	stream.idx = 0
	stream.on_done = opts.on_done -- called once when the queue drains
	-- Bound the region with two marks: top stays put, bottom rides down as we type.
	stream.top_mark = vim.api.nvim_buf_set_extmark(stream.buf, edit_ns, row, col, {
		right_gravity = false,
		virt_lines_above = true,
		virt_lines = { { { IMPL_LABEL, "TandemImplementing" } } },
	})
	stream.bot_mark = vim.api.nvim_buf_set_extmark(stream.buf, edit_ns, row, col, {
		right_gravity = true,
		virt_lines = { { { IMPL_LABEL, "TandemImplementing" } } },
	})
	M.active_edit = { buf = stream.buf, top = stream.top_mark, bot = stream.bot_mark, srow = row, erow = row }
	start_timer()
end

-- Pause: stop the timer but keep our place.
function M.pause()
	if stream.timer then
		vim.fn.timer_stop(stream.timer)
		stream.timer = nil
	end
end

-- Resume from where we paused.
function M.resume()
	if not stream.timer then
		start_timer()
	end
end

-- Drop the AI's region marks + highlight.
function M.clear_edit()
	if M.active_edit and vim.api.nvim_buf_is_valid(M.active_edit.buf) then
		vim.api.nvim_buf_clear_namespace(M.active_edit.buf, edit_ns, 0, -1)
	end
	M.active_edit = nil
	stream.top_mark, stream.bot_mark = nil, nil
end

-- Jump to wherever the AI is currently (or was last) writing code. Moves you into
-- a real code window — never a Tandem float — and centres on the edit.
function M.jump_to_edit()
	local e = M.active_edit
	if not e or not vim.api.nvim_buf_is_valid(e.buf) then
		vim.notify("Tandem: no active edit to jump to")
		return
	end
	-- prefer a window already showing the edited buffer; else any normal window
	local target
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(w).relative == "" then -- skip floats
			if vim.api.nvim_win_get_buf(w) == e.buf then
				target = w
				break
			end
			target = target or w
		end
	end
	if not target then
		vim.notify("Tandem: no normal window to jump in")
		return
	end
	vim.api.nvim_set_current_win(target)
	if vim.api.nvim_win_get_buf(target) ~= e.buf then
		vim.api.nvim_win_set_buf(target, e.buf)
	end
	local top = e.top and mark_pos(e.buf, e.top) -- live position (tracked your edits)
	local row = math.min((top or e.srow or 0) + 1, vim.api.nvim_buf_line_count(e.buf))
	vim.api.nvim_win_set_cursor(target, { row, 0 })
	vim.cmd("normal! zz")
end

function M.bubble(lines)
	lines = lines or { "Tandem 👁  — ask me anything" }

	-- 1. a scratch buffer to hold the bubble's contents
	local buf = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- 2. size the window to fit the content
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, #l)
	end

	-- 3. open a float anchored to the cursor
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor", -- position is measured from the cursor
		row = 1,
		col = 2, -- 1 row below, 2 cols right → the "tail" origin
		width = width + 1,
		height = #lines,
		style = "minimal", -- no line numbers/signs inside the bubble
		border = "rounded",
	})

	-- 4. q or <Esc> closes it (buffer-local, so only inside the bubble)
	local function close()
		vim.api.nvim_win_close(win, true)
	end
	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })

	return win, buf
end

-- `opts` (optional): { title, on_cancel }. on_cancel fires if you dismiss with <Esc>
-- (so a blocked question still gets released).
function M.ask(on_submit, opts)
	opts = opts or {}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		anchor = "SW", -- above the cursor line
		row = 0,
		col = 2,
		width = 50,
		height = 1,
		style = "minimal",
		border = "rounded",
		title = opts.title or " ask tandem ",
		title_pos = "center",
	})
	vim.wo[win].winhighlight = "FloatBorder:TandemBorderActive"
	mark_surface(win)
	vim.cmd("startinsert") -- drop straight into insert mode, ready to type

	-- submit: grab the buffer text, close, hand it to the callback
	vim.keymap.set("i", "<CR>", function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		vim.api.nvim_win_close(win, true)
		if on_submit then
			on_submit(text)
		end
	end, { buffer = buf })

	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
		if opts.on_cancel then
			opts.on_cancel()
		end
	end, { buffer = buf })
end

function M.chat()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "prompt" -- transcript + input line
	vim.fn.prompt_setprompt(buf, "you ▸ ")

	vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		row = 1,
		col = 2,
		width = 60,
		height = 10, -- fixed height; scrolls past this
		style = "minimal",
		border = "rounded",
		title = " tandem ",
		title_pos = "center",
	})

	-- Fires once per <CR>. `input` is what you typed.
	vim.fn.prompt_setcallback(buf, function(input)
		if input == "" then
			return
		end
		-- STUB reply (the model goes here later). Append above the next prompt.
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "tandem ▸ you said: " .. input, "" })
	end)

	vim.cmd("startinsert")
end

-- Grab the visually-selected lines (line-wise) as a single string.
-- Uses getpos("v")/(".") which are valid DURING visual mode, unlike the '< '>
-- marks (those only update when you leave visual mode → stale here).
local function get_visual_selection()
	local a = vim.fn.getpos("v") -- the visual anchor
	local b = vim.fn.getpos(".") -- the cursor
	local srow, erow = a[2], b[2]
	if srow > erow then
		srow, erow = erow, srow
	end
	return table.concat(vim.api.nvim_buf_get_lines(0, srow - 1, erow, false), "\n")
end

-- ── Shared panel: conversation + input + rail ───────────────────
-- The standard Tandem surface, used by BOTH the command centre (big, centred) and
-- located bubbles (small, at the cursor): a transcript pane (top-left), a "> " input
-- pane (bottom-left), and the read-only attribute rail (right). Returns the buffers/
-- windows + helpers; the caller wires what happens on submit. `box` carries the outer
-- geometry { T, L, Wt, Ht, rail_w, input_h, min_lw } in editor cells.
local function make_panel(box, title_label)
	local T, L, Wt, Ht = box.T, box.L, box.Wt, box.Ht
	local RW = box.rail_w or 0
	local LW = box.no_rail and Wt or math.max(box.min_lw or 24, Wt - RW - 1)
	local IH = box.input_h
	local CH = math.max(3, Ht - IH - 1)

	local conv_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[conv_buf].bufhidden = "wipe"
	local input_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[input_buf].bufhidden = "wipe"
	vim.bo[input_buf].buftype = "prompt"
	vim.fn.prompt_setprompt(input_buf, "> ")

	local conv_win = vim.api.nvim_open_win(conv_buf, false, {
		relative = "editor", row = T + 1, col = L + 1, width = LW - 2, height = CH - 2,
		style = "minimal", border = "rounded", title = " " .. title_label .. " ", title_pos = "left",
	})
	local input_win = vim.api.nvim_open_win(input_buf, true, {
		relative = "editor", row = T + CH + 2, col = L + 1, width = LW - 2, height = IH - 2,
		style = "minimal", border = "rounded", title = " message ", title_pos = "left",
	})
	vim.wo[conv_win].wrap, vim.wo[conv_win].linebreak = true, true
	style_markdown(conv_buf, conv_win)
	vim.wo[input_win].wrap = true
	mark_surface(conv_win)
	mark_surface(input_win)

	local rail_buf, rail_win
	if not box.no_rail then
		rail_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[rail_buf].bufhidden = "wipe"
		rail_win = vim.api.nvim_open_win(rail_buf, false, {
			relative = "editor", row = T + 1, col = L + LW + 1, width = RW - 2, height = Ht - 2,
			style = "minimal", border = "rounded", focusable = false,
		})
		vim.wo[rail_win].winhighlight = "FloatBorder:TandemBorderDim"
		mark_surface(rail_win)
		M._rail_buf, M._rail_win = rail_buf, rail_win
		M._rail_todo = box.todo ~= false -- bubbles omit the TO-DO panel (settings only)
		M.render_rail(rail_buf, M._rail_todo)
	end

	local P = {
		conv_buf = conv_buf, conv_win = conv_win,
		input_buf = input_buf, input_win = input_win,
		rail_buf = rail_buf, rail_win = rail_win,
	}

	function P.close()
		if M._rail_buf == rail_buf then
			M._rail_buf, M._rail_win = nil, nil
		end
		if M._close_chat == P.close then
			M._close_chat = nil
		end
		for _, w in ipairs({ conv_win, input_win, rail_win }) do
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end
	end
	M._close_chat = P.close -- so Follow can dismiss the panel when it covers your code

	local function set_active(win)
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		vim.api.nvim_set_current_win(win)
		for _, w in ipairs({ conv_win, input_win }) do
			if vim.api.nvim_win_is_valid(w) then
				vim.wo[w].winhighlight = (w == win) and "FloatBorder:TandemBorderActive"
					or "FloatBorder:TandemBorderDim"
			end
		end
	end
	function P.focus_input()
		set_active(input_win)
		vim.cmd("startinsert")
	end
	function P.focus_conv()
		set_active(conv_win)
	end

	-- append whole blocks to the transcript; autoscroll unless you're reading there.
	-- returns the 0-indexed start line where the block landed.
	function P.append(block)
		if not vim.api.nvim_buf_is_valid(conv_buf) then
			return
		end
		local cnt = vim.api.nvim_buf_line_count(conv_buf)
		local empty = (cnt == 1 and vim.api.nvim_buf_get_lines(conv_buf, 0, 1, false)[1] == "")
		local start = empty and 0 or cnt
		vim.api.nvim_buf_set_lines(conv_buf, start, empty and 1 or cnt, false, block)
		if vim.api.nvim_win_is_valid(conv_win) and vim.api.nvim_get_current_win() ~= conv_win then
			vim.api.nvim_win_set_cursor(conv_win, { vim.api.nvim_buf_line_count(conv_buf), 0 })
		end
		return start
	end

	-- append YOUR message as a grey-highlighted block (no "you ▸" prefix).
	function P.append_user(text)
		local lines = vim.split(text, "\n", { plain = true })
		local n = #lines
		lines[#lines + 1] = "" -- trailing gap
		local start = P.append(lines)
		if start then
			for i = start, start + n - 1 do
				pcall(vim.api.nvim_buf_set_extmark, conv_buf, chat_ns, i, 0, { line_hl_group = "TandemUserMsg" })
			end
		end
	end

	-- keymaps: Tab toggles panes; q closes; ? settings; <C-c> cancels; i/a/o → input
	for _, b in ipairs({ input_buf, conv_buf }) do
		vim.keymap.set("n", "q", P.close, { buffer = b })
		vim.keymap.set("n", "?", M.settings_menu, { buffer = b })
	end
	vim.keymap.set("n", "<Tab>", P.focus_conv, { buffer = input_buf })
	vim.keymap.set({ "n", "i" }, "<C-c>", M.cancel_all, { buffer = input_buf })
	-- @ → pick a file to reference (its content is injected into the prompt on send)
	vim.keymap.set("i", "@", function()
		M.pick_reference(function(choice)
			vim.api.nvim_put({ choice and ("@" .. choice .. " ") or "@" }, "c", true, true)
			vim.cmd("startinsert")
		end)
	end, { buffer = input_buf })
	vim.keymap.set("n", "<Tab>", P.focus_input, { buffer = conv_buf })
	vim.keymap.set("n", "<C-c>", M.cancel_all, { buffer = conv_buf })
	for _, k in ipairs({ "i", "a", "o", "I", "A" }) do
		vim.keymap.set("n", k, P.focus_input, { buffer = conv_buf })
	end

	return P
end

-- Stream one turn through a panel: echo the user's line, render the model's reply
-- into the transcript, then call on_done(acc) if given.
-- on_session(id) fires when the session id is learned; `fork` forks the session.
local function panel_turn(P, session, user_text, prompt_text, on_session, on_done, fork, opts)
	P.append_user(user_text)
	prompt_text = M.resolve_refs(prompt_text) -- pull in any @file references
	local acc, r_start, r_count = "", nil, nil
	M.prompt(session, prompt_text, function(msg)
		if msg.type == "session" then
			if on_session then
				on_session(msg.id)
			end
		elseif msg.type == "delta" then
			acc = acc .. msg.text
			if not vim.api.nvim_buf_is_valid(P.conv_buf) then
				return -- panel closed mid-stream; stop touching it
			end
			local lines = vim.split(acc, "\n", { plain = true })
			if not r_start then
				r_start = vim.api.nvim_buf_line_count(P.conv_buf)
				r_count = 0
			end
			vim.api.nvim_buf_set_lines(P.conv_buf, r_start, r_start + r_count, false, lines)
			r_count = #lines
			if vim.api.nvim_win_is_valid(P.conv_win) and vim.api.nvim_get_current_win() ~= P.conv_win then
				vim.api.nvim_win_set_cursor(P.conv_win, { vim.api.nvim_buf_line_count(P.conv_buf), 0 })
			end
		elseif msg.type == "done" then
			if r_start and vim.api.nvim_buf_is_valid(P.conv_buf) then
				local lines = vim.split(vim.trim(acc), "\n", { plain = true })
				lines[#lines + 1] = ""
				vim.api.nvim_buf_set_lines(P.conv_buf, r_start, r_start + r_count, false, lines)
				r_count = #lines
			end
			if on_done then
				on_done(acc)
			end
		end
	end, fork, opts)
end

-- Big centred box for the command centre.
local function centre_box()
	local Wt = math.floor(vim.o.columns * 0.86)
	local Ht = math.floor(vim.o.lines * 0.82)
	return {
		T = math.floor((vim.o.lines - Ht) / 2), L = math.floor((vim.o.columns - Wt) / 2),
		Wt = Wt, Ht = Ht, rail_w = 30, input_h = 5, min_lw = 40,
	}
end

-- Small box anchored just above the cursor for located bubbles.
local function cursor_box()
	local Wt = math.min(78, vim.o.columns - 4)
	local Ht = math.min(16, vim.o.lines - 4)
	local cr, cc = vim.fn.screenrow(), vim.fn.screencol()
	local T = cr - 2 - Ht -- above the cursor line
	if T < 0 then
		T = cr + 1 -- not enough room above → drop below the cursor
	end
	T = math.max(0, math.min(T, vim.o.lines - Ht - 1))
	local L = math.max(0, math.min(cc - 1, vim.o.columns - Wt - 1))
	return { T = T, L = L, Wt = Wt, Ht = Ht, rail_w = 22, input_h = 4, min_lw = 24, todo = false }
end

function M.chat_here(mode, scope, opts)
	mode = mode or "working" -- "working" | "ephemeral" | "fork"
	scope = scope or "line" -- "line" | "selection" | "file"
	opts = opts or {} -- { history = true } → render the session's prior messages on open
	-- where to project a suggestion back to (the code you're working on)
	local origin = { buf = vim.api.nvim_get_current_buf(), row = vim.api.nvim_win_get_cursor(0)[1] }
	local context
	if scope == "file" then
		context = {
			label = "the whole current file",
			text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
		}
	elseif scope == "selection" then
		context = { label = "the selected code", text = get_visual_selection() }
	else
		context = { label = "the line under my cursor", text = vim.api.nvim_get_current_line() }
	end

	-- For a Driver selection edit, remember the region's line range so we can mark it
	-- and have the Driver fill it in place (rather than rewriting the whole file).
	local sel_range
	if scope == "selection" then
		local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
		local srow, erow = a[2] - 1, b[2] - 1
		if srow > erow then
			srow, erow = erow, srow
		end
		sel_range = { srow = srow, erow = erow }
	end

	-- working shares M.active_session; ephemeral/fork keep a PRIVATE session
	local local_session = nil
	local function get_session()
		return mode == "working" and M.active_session or local_session
	end
	local function set_session(id)
		if mode == "working" then
			M.set_active_session(id) -- persist onto the active workpackage
		else
			local_session = id
		end
	end
	local bubble_first_turn = true

	-- the bubble: the SAME three-pane shape as the command centre, small + at cursor
	local P = make_panel(cursor_box(), "tandem · " .. mode)

	vim.fn.prompt_setcallback(P.input_buf, function(input)
		if input == "" then
			return
		end
		vim.schedule(function() -- keep the input box showing only the active "> " line
			if vim.api.nvim_buf_is_valid(P.input_buf) then
				local n = vim.api.nvim_buf_line_count(P.input_buf)
				if n > 1 then
					pcall(vim.api.nvim_buf_set_lines, P.input_buf, 0, n - 1, false, {})
				end
			end
		end)

		local cur = get_session()
		-- Fork off the working session, but only on turn 1 and only if one exists.
		local do_fork = (mode == "fork" and cur == nil and M.active_session ~= nil)
		local source = do_fork and M.active_session or cur

		local my_region -- the region this turn armed (if any), so its done-handler can withdraw it
		local parts = {}
		if cur == nil and mode == "working" then -- journal: fresh working session only
			local journal = M.read_journal()
			if journal ~= "" then
				parts[#parts + 1] = "Project journal (what we're working on):\n" .. journal
			end
		end
		if bubble_first_turn then -- this bubble's located code, on its first turn
			-- Send the REAL absolute path so the Driver writes back to this exact file
			-- (not a guessed name resolved against the wrong cwd).
			local fname = vim.api.nvim_buf_get_name(origin.buf)
			local where = (fname ~= "")
				and ("I'm editing this file — use exactly this path with tandem_write: " .. fname .. "\n")
				or ""
			parts[#parts + 1] = where .. "Context (" .. context.label .. "):\n" .. context.text
			-- Driver region edits: mark the target (in region_ns, so a concurrently-typing
			-- edit can't wipe it) and ARM it on the FIFO queue. Several can be armed at once —
			-- the Driver fills each via tandem_region, in order.
			if M.role == "driver" then
				local b = origin.buf
				local label = { { { IMPL_LABEL, "TandemImplementing" } } }
				if sel_range then
					-- SELECTION → replace it (shown marked, since you clearly want an edit)
					local last = vim.api.nvim_buf_get_lines(b, sel_range.erow, sel_range.erow + 1, false)[1] or ""
					local top = vim.api.nvim_buf_set_extmark(b, region_ns, sel_range.srow, 0, {
						right_gravity = false, virt_lines_above = true, virt_lines = label,
					})
					local bot = vim.api.nvim_buf_set_extmark(b, region_ns, sel_range.erow, #last, {
						right_gravity = true, virt_lines = label,
					})
					my_region = M.region_arm({ buf = b, top = top, bot = bot, kind = "replace" })
					parts[#parts + 1] =
						"IMPORTANT: implement this as a REGION edit. Call the tandem_region tool with ONLY the replacement code for the selected region — do not rewrite the whole file or use tandem_write."
				elseif scope == "line" then
					-- CURSOR → insert at the cursor. No label yet (could be just a question);
					-- markers appear once it actually writes.
					local cr = origin.row - 1
					local line = vim.api.nvim_buf_get_lines(b, cr, cr + 1, false)[1] or ""
					local top = vim.api.nvim_buf_set_extmark(b, region_ns, cr, #line, { right_gravity = false })
					local bot = vim.api.nvim_buf_set_extmark(b, region_ns, cr, #line, { right_gravity = true })
					my_region = M.region_arm({ buf = b, top = top, bot = bot, kind = "insert" })
					parts[#parts + 1] =
						"There is an insertion point marked at my cursor. If I'm asking you to write or insert code, call the tandem_region tool with ONLY that code (it will be placed at the marked point — do not rewrite the whole file). If I'm only asking a question, just answer normally."
				end
			end
		end
		bubble_first_turn = false
		parts[#parts + 1] = "Question: " .. input
		local text = (#parts == 1) and input or table.concat(parts, "\n\n")

		panel_turn(P, source, input, text, set_session, function(acc)
			-- Navigator / Neutral: offer the reply's fenced code blocks as ghosts.
			-- (Driver writes via the tandem_write / tandem_region tools → on_edit, so
			-- there's nothing to capture from the reply text here.)
			if M.role ~= "driver" then
				M.candidates = nil
				local blocks = M.extract_blocks(acc)
				if #blocks > 0 then
					M.candidates = { blocks = blocks, buf = origin.buf, row = origin.row }
					vim.notify(string.format("Tandem: %d code block%s — <leader>li to ghost", #blocks, #blocks > 1 and "s" or ""))
				end
			end
			-- this turn armed a region but the Driver never filled it (answered instead)
			-- → withdraw it so it doesn't linger for a later tandem_region call
			if my_region then
				M.region_withdraw(my_region)
				my_region = nil
			end
		end, do_fork)
	end)

	-- optionally show the prior conversation (bring back the "previous chat")
	if opts.history and get_session() then
		M.fetch_history(get_session(), function(messages)
			if not vim.api.nvim_buf_is_valid(P.conv_buf) then
				return
			end
			for _, m in ipairs(messages) do
				local txt = vim.trim(m.text or "")
				if txt ~= "" then
					if m.role == "user" then
						P.append_user(txt)
					else
						local lines = vim.split(txt, "\n", { plain = true })
						lines[#lines + 1] = ""
						P.append(lines)
					end
				end
			end
		end)
	end

	P.focus_input()
end

-- Re-open the working chat as a bubble at the cursor, showing the conversation so far.
function M.reopen_chat()
	M.chat_here("working", "line", { history = true })
end

-- ── OpenCode backend ─────────────────────────────────────────────
-- local SERVER = "http://127.0.0.1:4096"
--
-- -- POST `body` (a Lua table) as JSON to `path`; return the decoded response.
-- local function http_post(path, body)
-- 	local res = vim.system({
-- 		"curl",
-- 		"-s",
-- 		"-X",
-- 		"POST",
-- 		SERVER .. path,
-- 		"-H",
-- 		"Content-Type: application/json",
-- 		"-d",
-- 		vim.json.encode(body),
-- 	}, { text = true }):wait()
-- 	return vim.json.decode(res.stdout)
-- end
--
-- -- Create a session bound to the free zen model; return its id (ses_…).
-- function M.new_session()
-- 	local resp = http_post("/api/session", {
-- 		model = { providerID = "opencode", id = "north-mini-code-free" },
-- 	})
-- 	return resp.data.id
-- end

-- Plugin root, derived from THIS file's location (lua/tandem/init.lua → up 3), so the
-- sidecar/agents paths work wherever the repo lives — no hardcoded project dir.
local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local SIDECAR = PLUGIN_ROOT .. "/sidecar/sidecar.mjs"

-- Run the sidecar with `prompt`; call on_delta(text) per chunk, on_done() at end.
function M.ask_stream(prompt, on_delta, on_done)
	vim.fn.jobstart({ "node", SIDECAR, prompt }, {
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then
					local ok, msg = pcall(vim.json.decode, line) -- each line is one JSON object
					if ok and msg.type == "delta" then
						on_delta(msg.text)
					elseif ok and msg.type == "done" and on_done then
						on_done()
					end
				end
			end
		end,
	})
end

function M.ask_bubble(prompt)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_open_win(buf, false, {
		relative = "cursor",
		row = 1,
		col = 2,
		width = 60,
		height = 12,
		style = "minimal",
		border = "rounded",
		title = " tandem ",
		title_pos = "center",
	})
	local reply = ""
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "…" })

	M.ask_stream(
		prompt,
		function(delta) -- on each chunk
			reply = reply .. delta
			local lines = vim.split(reply, "\n", { plain = true })
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		end,
		function() end -- on done (nothing extra for now)
	)
end

-- Ask a question about the line under the cursor; stream the answer in a bubble.
function M.ask_here()
	local line = vim.api.nvim_get_current_line()
	M.ask(function(question)
		local prompt = table.concat({
			"Here is a line of code from the file I'm editing:",
			"",
			line,
			"",
			"My question: " .. question,
		}, "\n")
		M.ask_bubble(prompt)
	end)
end

local DAEMON = PLUGIN_ROOT .. "/sidecar/daemon.mjs"

local daemon = {
	job = nil,
	ready = false,
	queue = {}, -- commands waiting for the daemon to boot
	handlers = {}, -- tag -> function(msg)  (who's listening for each request)
	buf = "", -- partial-line reassembly buffer
	n = 0, -- tag counter
}

-- Reassemble stdout into whole JSON lines, then route each by tag.
local function on_stdout(_, data)
	daemon.buf = daemon.buf .. table.concat(data, "\n") -- see note on this
	while true do
		local nl = daemon.buf:find("\n", 1, true)
		if not nl then
			break
		end
		local line = daemon.buf:sub(1, nl - 1)
		daemon.buf = daemon.buf:sub(nl + 1)
		if line ~= "" then
			local ok, msg = pcall(vim.json.decode, line)
			if ok then
				if msg.type == "ready" then
					daemon.ready = true
                    M.daemon_version = msg.version
                    vim.notify("Tandem daemon: " .. (msg.version or "unknown"))
					for _, c in ipairs(daemon.queue) do
						vim.fn.chansend(daemon.job, vim.json.encode(c) .. "\n")
					end
					daemon.queue = {}
				elseif msg.type == "edit" then
					M.on_edit(msg) -- the agent's tandem_write tool wants to write a file
				elseif msg.type == "region" then
					M.on_region(msg) -- the agent's tandem_region tool — replace the marked region
				elseif msg.type == "ask" then
					M.on_ask(msg) -- the agent's tandem_ask tool — needs a decision from you
				elseif msg.type == "notify" then
					M.on_notify(msg) -- the agent's tandem_notify tool — a status line
				elseif msg.type == "instruct" then
					M.on_instruct(msg) -- the Navigator's tandem_instruct tool — a directive
				elseif msg.type == "journal" then
					M.on_journal(msg) -- tandem_journal tool — curate the workpackage brief
				elseif msg.type == "backlog" then
					M.on_backlog(msg) -- tandem_backlog tool — add/complete tasks
				elseif msg.type == "permission" then
					M.on_permission(msg) -- a side-effecting tool wants to run — ask first
				elseif msg.type == "status" then
					M.on_status(msg) -- one-line "what the AI is doing now"
				elseif daemon.handlers[msg.tag] then
					daemon.handlers[msg.tag](msg)
				end
			end
		end
	end
end

local function ensure_daemon()
	if daemon.job then
		return
	end
	daemon.job = vim.fn.jobstart({ "node", DAEMON }, {
		on_stdout = on_stdout,
		on_exit = function(_, code)
			daemon.job = nil
			daemon.ready = false
			if next(daemon.handlers) ~= nil then -- died mid-request
				vim.schedule(function()
					M.toast("⚠ Tandem daemon stopped (exit " .. tostring(code) .. ")", { title = " tandem ", timeout = 8000 })
				end)
			end
			daemon.handlers = {}
			M.activity_reset()
		end,
	})
end

function M.restart_daemon()
	if daemon.job then
		vim.fn.jobstop(daemon.job)
	end
	daemon.job, daemon.ready, daemon.queue = nil, false, {}
	vim.notify("Tandem: daemon restarted")
end

local function send_cmd(cmd)
	ensure_daemon()
	if daemon.ready then
		vim.fn.chansend(daemon.job, vim.json.encode(cmd) .. "\n")
	else
		table.insert(daemon.queue, cmd) -- not booted yet → queue it
	end
end

-- Run the typewriter now, or — when Follow is ON — hold it behind a confirmation so
-- you always watch each write start. `fn` performs the actual type_out.
local function gated_write(fn)
	if M.follow then
		M._pending_write = fn
		M.toast("▶ ready to write here — confirm to watch it type", { sticky = true, title = " follow · confirm " })
	else
		fn()
	end
end

-- Confirm a held write (Follow mode): let the AI start typing.
function M.confirm_write()
	local fn = M._pending_write
	M._pending_write = nil
	M.toast_dismiss()
	if fn then
		fn()
	else
		vim.notify("Tandem: nothing waiting to write")
	end
end

-- Serialize concurrent edits: the typewriter is single-stream, so when the agent
-- issues several writes/regions in one turn (parallel tool calls), we run them ONE
-- AT A TIME in arrival order. `M._edit_busy` is claimed by the FIRST edit and held
-- until the queue fully drains — so an edit arriving in the gap between one finishing
-- and the next starting (the agent fires its next tandem_write the instant it gets
-- edit_done) still queues behind, instead of racing ahead. Each queued tool stays
-- blocked (no edit_done) until its turn, so the agent's ordering is preserved.
M._edit_queue = M._edit_queue or {}
M._edit_busy = M._edit_busy or false

-- True while an edit is in flight OR queued OR held behind a Follow confirmation.
function M.busy_editing()
	return M._edit_busy or M._pending_write ~= nil
end

-- An edit fully finished: run the next queued one directly (we still own the busy
-- slot — dequeued items bypass the gate), or release the slot if the queue is empty.
function M._edit_next()
	local item = table.remove(M._edit_queue, 1)
	if item then
		vim.schedule(function()
			if item.kind == "region" then
				M._do_region(item.msg)
			else
				M._do_edit(item.msg)
			end
		end)
	else
		M._edit_busy = false
	end
end

-- Cancel path: release every queued (still-blocked) tool, empty the queue, and drop
-- the busy claim — so nothing fires after a stop.
function M._drain_edit_queue()
	local q = M._edit_queue
	M._edit_queue = {}
	M._edit_busy = false
	for _, item in ipairs(q) do
		send_cmd({ cmd = "edit_done", id = item.id, message = "cancelled" })
	end
end

-- Gate an incoming edit: if something is already in flight, queue it (by kind + msg,
-- keyed on tool id so cancel can release it) and report true. Otherwise claim the
-- busy slot and report false so the caller runs its body now.
local function defer_if_busy(kind, msg)
	if M.busy_editing() then
		table.insert(M._edit_queue, { id = msg.id, kind = kind, msg = msg })
		return true
	end
	M._edit_busy = true
	return false
end

-- ── Pending regions (FIFO) ──────────────────────────────────────
-- Each "select a region + ask" arms a region (its own marks in region_ns). Several
-- can be armed at once; they're consumed in ORDER by tandem_region calls (turns run
-- sequentially, so the Nth tandem_region belongs to the Nth armed region). An entry is
-- { buf, top, bot, kind, ns }.
M._region_queue = M._region_queue or {}

-- Delete a region entry's marks (its ⟨implementing⟩ labels), if still present.
local function region_clear_marks(e)
	if e and e.buf and vim.api.nvim_buf_is_valid(e.buf) then
		pcall(vim.api.nvim_buf_del_extmark, e.buf, e.ns or region_ns, e.top)
		pcall(vim.api.nvim_buf_del_extmark, e.buf, e.ns or region_ns, e.bot)
	end
end

-- Arm a region: remember its marks and return the entry (kept by the caller so it can
-- withdraw it if the turn ends without editing).
function M.region_arm(entry)
	entry.ns = entry.ns or region_ns
	M._region_queue[#M._region_queue + 1] = entry
	return entry
end

-- Withdraw a specific armed region (the turn answered instead of editing it).
function M.region_withdraw(entry)
	for i, e in ipairs(M._region_queue) do
		if e == entry then
			table.remove(M._region_queue, i)
			region_clear_marks(e)
			return
		end
	end
end

-- Any region currently armed? (front of the queue, if its buffer is still valid.)
function M.region_pending()
	local e = M._region_queue[1]
	if e and vim.api.nvim_buf_is_valid(e.buf) then
		return e
	end
	return nil
end

-- Cancel path: drop every armed region + its marks.
function M._drain_region_queue()
	local q = M._region_queue
	M._region_queue = {}
	for _, e in ipairs(q) do
		region_clear_marks(e)
	end
end

-- The agent's tandem_write tool (via the daemon bridge) wants to write a file. We
-- own application: type the content into the buffer with the watchable typewriter,
-- persist it, then ack so the blocked tool returns and the agent continues.
-- We do NOT steal focus (Follow-off behaviour) — <leader>lg jumps you to it.
function M.on_edit(msg)
	-- An edit is already in flight → wait our turn (serialized; see M._edit_queue).
	if defer_if_busy("edit", msg) then
		return
	end
	M._do_edit(msg)
end

-- The body of a write, run once it owns the busy slot (either immediately from the
-- gate, or when dequeued). Never call this directly — go through M.on_edit.
function M._do_edit(msg)
	-- Safety net: if a region is armed (you selected/marked a spot), the Driver should
	-- have used tandem_region. If it used tandem_write instead, still apply to the armed
	-- REGION — never blow away the whole file. (Call the body directly: we own the slot.)
	if M.region_pending() then
		return M._do_region({ id = msg.id, content = msg.content })
	end
	local file = msg.file or ""
	if file == "" then
		send_cmd({ cmd = "edit_done", id = msg.id, message = "no file given" })
		M._edit_next()
		return
	end
	if not file:match("^/") then -- resolve relative paths against cwd
		file = vim.fn.getcwd() .. "/" .. file
	end
	local buf = vim.fn.bufadd(file)
	vim.fn.bufload(buf)
	vim.bo[buf].buflisted = true
	M._edit = { id = msg.id, buf = buf, file = file }
	local name = vim.fn.fnamemodify(file, ":t")

	-- persist to disk + ack the blocked tool so the agent continues
	local function finish()
		pcall(function()
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("silent keepalt noautocmd write")
			end)
		end)
		M._edit = nil
		send_cmd({ cmd = "edit_done", id = msg.id, message = "wrote " .. file })
		M._edit_next() -- run the next queued edit, if any
	end

	-- DIFF-BASED application: type only the changed span, leaving untouched code
	-- alone. (tandem_write sends the whole file; we diff it against the buffer and
	-- find the minimal contiguous range that changed.)
	local incoming = msg.content or ""
	local new_lines = vim.split(incoming, "\n", { plain = true })
	local cur_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local a_lo, a_hi, b_lo, b_hi
	if #cur_lines == 1 and cur_lines[1] == "" then
		-- empty/new file: replace the lone blank line with the whole content
		a_lo, a_hi, b_lo, b_hi = 0, 1, 0, #new_lines
	else
		local hunks = vim.diff(table.concat(cur_lines, "\n"), incoming, { result_type = "indices" })
		if not hunks or #hunks == 0 then
			finish() -- file already matches what the AI sent; nothing to type
			return
		end
		-- collapse all hunks into one [a_lo,a_hi) buffer range ↔ [b_lo,b_hi) new range
		for _, h in ipairs(hunks) do
			local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
			local das = (ca > 0) and (sa - 1) or sa -- 0-indexed delete range in the buffer
			local dbs = (cb > 0) and (sb - 1) or sb -- 0-indexed insert range in the new lines
			a_lo, a_hi = math.min(a_lo or das, das), math.max(a_hi or das + ca, das + ca)
			b_lo, b_hi = math.min(b_lo or dbs, dbs), math.max(b_hi or dbs + cb, dbs + cb)
		end
	end

	-- Follow ON: dismiss the covering chat and jump to the change so you watch it.
	if M.follow then
		if M._close_chat then
			pcall(M._close_chat)
		end
		M.show_buf(buf, a_lo + 1)
		M.toast("✎ following: " .. name)
	else
		M.toast("✎ editing " .. name .. " — <leader>lg to follow")
	end

	if b_hi <= b_lo then -- pure deletion: drop the lines, nothing to type
		vim.api.nvim_buf_set_lines(buf, a_lo, a_hi, false, {})
		finish()
		return
	end
	-- reserve a single line where the change goes, then typewrite the new span into it
	local span = {}
	for i = b_lo + 1, b_hi do
		span[#span + 1] = new_lines[i]
	end
	vim.api.nvim_buf_set_lines(buf, a_lo, a_hi, false, { "" })
	local intervals = { char = 38, word = 75, line = 120, paragraph = 250 }
	local gran = M.granularity
	gated_write(function()
		M.type_out(table.concat(span, "\n"), {
			buf = buf,
			row = a_lo,
			col = 0,
			granularity = gran,
			interval = intervals[gran] or 35,
			on_done = finish,
		})
	end)
end

-- The agent's tandem_region tool: replace ONLY a marked region (a selection the user
-- pointed at) with the returned snippet — typed in via the mark-anchored typewriter,
-- so you can keep editing outside it. Regions are consumed FIFO from M._region_queue:
-- the Nth tandem_region call fills the Nth region you armed.
function M.on_region(msg)
	-- Serialize behind any edit already in flight (see M._edit_queue).
	if defer_if_busy("region", msg) then
		return
	end
	M._do_region(msg)
end

-- The body of a region edit, run once it owns the busy slot. Go through M.on_region.
function M._do_region(msg)
	local r = table.remove(M._region_queue, 1) -- oldest armed region
	while r and not vim.api.nvim_buf_is_valid(r.buf) do -- skip any whose buffer is gone
		r = table.remove(M._region_queue, 1)
	end
	if not r then
		send_cmd({ cmd = "edit_done", id = msg.id, message = "no active region to edit" })
		M._edit_next()
		return
	end
	local tr, tc = mark_pos_ns(r.buf, r.ns or region_ns, r.top)
	local br, bc = mark_pos_ns(r.buf, r.ns or region_ns, r.bot)
	region_clear_marks(r) -- consumed → drop its ⟨implementing⟩ labels
	if not tr or not br then
		send_cmd({ cmd = "edit_done", id = msg.id, message = "region markers were lost" })
		M._edit_next()
		return
	end
	-- register as the in-flight edit so M.interrupt_edit can pause it
	M._edit = { id = msg.id, buf = r.buf }
	local content = msg.content or ""
	if r.kind == "insert" then
		content = "\n" .. content -- new lines just below the marked point (cursor)
	else
		-- replace: clear the old region content, collapsing to the point at (tr,tc)
		pcall(vim.api.nvim_buf_set_text, r.buf, tr, tc, br, bc, { "" })
	end
	if M.follow then
		if M._close_chat then
			pcall(M._close_chat)
		end
		M.show_buf(r.buf, tr + 1)
		M.toast("✎ implementing region")
	else
		M.toast("✎ implementing region — <leader>lg to follow")
	end
	local intervals = { char = 38, word = 75, line = 120, paragraph = 250 }
	local gran = M.granularity
	gated_write(function()
		M.type_out(content, {
			buf = r.buf,
			row = tr,
			col = tc,
			granularity = gran,
			interval = intervals[gran] or 35,
			on_done = function()
				pcall(function()
					vim.api.nvim_buf_call(r.buf, function()
						vim.cmd("silent keepalt noautocmd write")
					end)
				end)
				M._edit = nil -- region edit completed normally
				send_cmd({ cmd = "edit_done", id = msg.id, message = "applied region edit" })
				M._edit_next() -- run the next queued edit, if any
			end,
		})
	end)
end

-- The agent's tandem_ask tool: it needs a decision and is BLOCKED until you answer.
-- We show the question and open an input; your answer (or a dismissal) is sent back
-- as the tool result so the agent continues.
function M.on_ask(msg)
	local question = msg.question or "?"
	-- A forked side-chat at the bottom of the screen: DISCUSS the question with a fork
	-- (which has the full context) via Enter, then ^S to send your final answer — that
	-- unblocks the original agent. The main agent stays frozen the whole time.
	local W = math.floor(vim.o.columns * 0.7)
	local H = math.min(16, vim.o.lines - 4)
	local box = {
		T = vim.o.lines - H - 2,
		L = math.max(0, math.floor((vim.o.columns - W) / 2)),
		Wt = W, Ht = H, input_h = 4, no_rail = true,
	}
	local P = make_panel(box, "tandem asks · Enter = discuss · ^S = send answer")
	P.append(vim.split(question, "\n", { plain = true }))
	P.append({ "" })

	local fork_session, answered = nil, false
	local function answer_with(text)
		if answered then
			return
		end
		answered = true
		send_cmd({
			cmd = "edit_done",
			id = msg.id,
			message = (text and text ~= "") and text or "(no answer — use your best judgement)",
		})
		P.close()
	end

	local discuss_system = 'You previously asked the user this question and they want to discuss it before deciding: "'
		.. question
		.. '". Talk it through — clarify what you meant, lay out options and trade-offs. Reply in plain text ONLY; do NOT call tandem_write, tandem_region, tandem_ask, tandem_instruct or any edit tool.'

	-- Enter: discuss with a FORK of the working session (it inherits the context).
	vim.fn.prompt_setcallback(P.input_buf, function(input)
		if input == "" then
			return
		end
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(P.input_buf) then
				local n = vim.api.nvim_buf_line_count(P.input_buf)
				if n > 1 then
					pcall(vim.api.nvim_buf_set_lines, P.input_buf, 0, n - 1, false, {})
				end
			end
		end)
		local do_fork = (fork_session == nil and M.active_session ~= nil)
		local source = do_fork and M.active_session or fork_session
		panel_turn(P, source, input, input, function(id)
			fork_session = id
		end, nil, do_fork, {
			system = discuss_system,
			agent = "plan",
			tools = { write = false, edit = false, patch = false },
		})
	end)

	-- ^S: take the current input line as the final answer (unblocks the agent).
	local function submit_answer()
		local lines = vim.api.nvim_buf_get_lines(P.input_buf, 0, -1, false)
		local last = lines[#lines] or ""
		answer_with(vim.trim((last:gsub("^> ?", ""))))
	end
	for _, b in ipairs({ P.input_buf, P.conv_buf }) do
		vim.keymap.set({ "n", "i" }, "<C-s>", submit_answer, { buffer = b })
		vim.keymap.set({ "n", "i" }, "<C-c>", function()
			answer_with("(the user dismissed the question; use your best judgement)")
		end, { buffer = b })
		vim.keymap.set("n", "q", function()
			answer_with("(the user dismissed the question; use your best judgement)")
		end, { buffer = b })
	end

	P.focus_input()
end

-- The agent's tandem_notify tool: a transient status line (non-blocking).
function M.on_notify(msg)
	if msg.message and msg.message ~= "" then
		M.toast(msg.message)
	end
end

-- A side-effecting tool (bash, webfetch, …) wants to run. Ask before it does —
-- allow once / allow always (this daemon run) / reject. Dismissing rejects (safe
-- default: never run a command you didn't approve). Reads/greps + Tandem's own tools
-- are auto-allowed by the daemon and never reach here.
function M.on_permission(msg)
	local tool = msg.tool or "a tool"
	local command = msg.command or ""
	vim.schedule(function()
		local label = (command ~= "" and command ~= tool) and (tool .. " · " .. command) or tool
		vim.ui.select({ "Allow once", "Allow always (this session)", "Reject" }, {
			prompt = "Tandem — run  " .. label .. "  ?",
		}, function(choice)
			local decision = "reject"
			if choice == "Allow once" then
				decision = "once"
			elseif choice and choice:match("^Allow always") then
				decision = "always"
			end
			send_cmd({ cmd = "permission_reply", id = msg.id, decision = decision })
		end)
	end)
end

-- The Navigator's tandem_instruct tool: a directive (next step for you). Opens a
-- formatted (markdown) side-chat seeded with the instruction so you can SEE it nicely
-- and DISCUSS it (via a fork) before doing it — like the question flow, but since it's
-- non-blocking there's no answer to send: just q when you're ready to go do the work.
function M.on_instruct(msg)
	local instr = msg.instruction or ""
	if instr == "" then
		return
	end
	M.last_instruction = instr

	local W = math.floor(vim.o.columns * 0.7)
	local H = math.min(16, vim.o.lines - 4)
	local box = {
		T = vim.o.lines - H - 2,
		L = math.max(0, math.floor((vim.o.columns - W) / 2)),
		Wt = W, Ht = H, input_h = 4, no_rail = true,
	}
	local P = make_panel(box, "tandem · instruction · Enter = discuss · q = done")
	P.append(vim.split("▸ " .. instr, "\n", { plain = true }))
	P.append({ "" })

	local fork_session = nil
	local discuss_system = 'You gave the user this instruction and they want to discuss it before doing it: "'
		.. instr
		.. '". Clarify and talk it through in plain text ONLY. Do NOT issue new instructions or call any tool.'

	vim.fn.prompt_setcallback(P.input_buf, function(input)
		if input == "" then
			return
		end
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(P.input_buf) then
				local n = vim.api.nvim_buf_line_count(P.input_buf)
				if n > 1 then
					pcall(vim.api.nvim_buf_set_lines, P.input_buf, 0, n - 1, false, {})
				end
			end
		end)
		-- fork the working session so discussion never collides with the main turn
		local do_fork = (fork_session == nil and M.active_session ~= nil)
		local source = do_fork and M.active_session or fork_session
		panel_turn(P, source, input, input, function(id)
			fork_session = id
		end, nil, do_fork, {
			system = discuss_system,
			agent = "plan",
			tools = { write = false, edit = false, patch = false },
		})
	end)

	P.focus_input()
end

-- PAUSE the AI mid-write so you can take the floor. Freezes the typewriter and ENDS
-- the agent's turn (releases the blocked tandem_write tool) so the agent is free to
-- talk. Your half-written file stays as-is. Now open a bubble / the main chat and
-- have a real back-and-forth — same session, so it's all remembered. When you're
-- happy, M.continue_work() tells it to carry on with everything that just happened.
function M.interrupt_edit()
	local e = M._edit
	if not e or not vim.api.nvim_buf_is_valid(e.buf) then
		vim.notify("Tandem: nothing is being written to pause")
		return
	end
	M.pause() -- freeze the typewriter
	M._drain_edit_queue() -- release any writes queued behind this one (turn is ending)
	M._drain_region_queue() -- withdraw any regions armed for this turn
	stream.on_done = nil -- don't let a stray resume auto-ack
	stream.idx = #stream.chunks -- neutralise the queue
	M._edit = nil
	-- KEEP the region marks (the held region) so it stays bounded + tracked while you
	-- take over; remember them so continue can resume into the same place.
	local ae = M.active_edit
	M._held = { session = M.active_session, file = e.file, buf = e.buf, top = ae and ae.top, bot = ae and ae.bot }
	-- relabel the markers ⟨ paused ⟩
	if ae and ae.top then
		local tr, tc = mark_pos(e.buf, ae.top)
		if tr then
			pcall(vim.api.nvim_buf_set_extmark, e.buf, edit_ns, tr, tc, {
				id = ae.top, right_gravity = false, virt_lines_above = true,
				virt_lines = { { { "⟨ paused — <leader>lc to continue ⟩", "TandemImplementing" } } },
			})
		end
		local br, bc = mark_pos(e.buf, ae.bot)
		if br then
			pcall(vim.api.nvim_buf_set_extmark, e.buf, edit_ns, br, bc, {
				id = ae.bot, right_gravity = true,
				virt_lines = { { { "⟨ paused ⟩", "TandemImplementing" } } },
			})
		end
	end
	-- keep whatever's in the buffer now (the AI's partial work + any edits you made)
	pcall(function()
		vim.api.nvim_buf_call(e.buf, function()
			vim.cmd("silent keepalt noautocmd write")
		end)
	end)
	-- release the agent: end the turn and tell it to WAIT rather than keep writing
	send_cmd({
		cmd = "edit_done",
		id = e.id,
		message = "The user pressed PAUSE to take over for a moment. Stop writing — do NOT call tandem_write again now. Reply with one short sentence acknowledging, then wait for their next message.",
	})
	M.toast("⏸ paused — chat / edit freely; <leader>lc when you want it to continue", { sticky = true })
end

-- CONTINUE: hand control back. Resume the paused work with everything that happened
-- since (your questions, redirections, edits) as context — and, if we still have the
-- held region's marks, the region's ACTUAL current text so it resumes from your reality.
function M.continue_work()
	if not M.active_session then
		vim.notify("Tandem: no session to continue")
		return
	end
	local held = M._held
	M._held = nil
	M.toast_dismiss()
	M.toast("▶ continuing where we left off…")
	local extra = ""
	local armed -- the region we re-arm for the continuation (if any)
	if held and held.top and vim.api.nvim_buf_is_valid(held.buf) then
		local tr, tc = mark_pos(held.buf, held.top)
		local br, bc = mark_pos(held.buf, held.bot)
		if tr and br then
			local cur = table.concat(vim.api.nvim_buf_get_text(held.buf, tr, tc, br, bc, {}), "\n")
			extra = "\n\nThe marked region currently contains this (including any edits I made):\n"
				.. cur
				.. "\n\nReturn the COMPLETE finished code for THIS region via tandem_region — it replaces only the marked region; do NOT rewrite the rest of the file."
			-- keep the held marks and scope the continuation to them, so it re-types
			-- only the region (not the whole file). The held marks live in edit_ns.
			armed = M.region_arm({ buf = held.buf, top = held.top, bot = held.bot, kind = "replace", ns = edit_ns })
		end
	end
	if not armed then
		M.clear_edit() -- no held region → just continue normally
	end
	M.run(
		M.active_session,
		"Continue the work you paused earlier. Take our discussion since then, and any edits I made to the file myself, into account — then resume writing." .. extra
	)
end

-- Show `buf` in a real (non-floating) window and focus it, cursor at `row` (1-based).
function M.show_buf(buf, row)
	local win
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(w).relative == "" then -- skip floats
			win = win or w
			if vim.api.nvim_win_get_buf(w) == buf then
				win = w
				break
			end
		end
	end
	if not win then
		return
	end
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_set_current_win(win)
	pcall(vim.api.nvim_win_set_cursor, win, { row or 1, 0 })
end

function M.cancel(session)
	if session then
		send_cmd({ cmd = "cancel", session = session, backend = M.backend() })
	end
end

-- Global cancel: stop EVERYTHING Tandem is doing — abort all running turns, stop the
-- typewriter mid-type, and clear the spinner / toasts / pending question.
function M.cancel_all()
	M.pause() -- stop any in-progress typing
	M._drain_edit_queue() -- release any queued (blocked) writes
	M._drain_region_queue() -- withdraw any armed regions
	if daemon.job and daemon.ready then
		vim.fn.chansend(daemon.job, vim.json.encode({ cmd = "cancel_all" }) .. "\n")
	end
	M.activity_reset()
	M.toast_dismiss()
	vim.notify("Tandem: cancelled")
end

-- Stream a prompt. `session` is nil (new) or a "ses_…" id (continue).
-- on_event(msg) receives each tagged event: session / delta / done / error.
-- `opts` (optional) overrides { system, agent, tools } — used for one-off tasks
-- (e.g. review summaries) that shouldn't run as the current pairing role.
function M.prompt(session, text, on_event, fork, opts)
	opts = opts or {}
	daemon.n = daemon.n + 1
	local tag = "t" .. daemon.n
	M.activity_start()
	daemon.handlers[tag] = function(msg)
		on_event(msg)
		if msg.type == "error" then
			M.toast("⚠ " .. (type(msg.error) == "string" and msg.error or vim.inspect(msg.error)), {
				title = " tandem error ",
				timeout = 8000,
			})
		end
		if msg.type == "done" or msg.type == "error" then
			daemon.handlers[tag] = nil -- request finished; stop listening
			M.activity_stop()
		end
	end
	send_cmd({
		cmd = "prompt",
		tag = tag,
		session = session,
		text = text,
		fork = fork,
		backend = M.backend(),
		model = M.active_model and { providerID = M.active_model.providerID, modelID = M.active_model.modelID } or nil,
		system = opts.system or M.build_system(), -- per-role behaviour from the agent files
		agent = opts.agent or (({ navigator = "plan", neutral = "build", driver = "build" })[M.role] or "build"),
		-- Driver writes ONLY through tandem_write (watchable typewriter) — disable the
		-- native writers so it can't bypass Tandem and clobber files on disk.
		tools = opts.tools ~= nil and opts.tools
			or ((M.role == "driver") and { write = false, edit = false, patch = false } or nil),
	})
end

-- Fetch a session's prior messages; cb(messages) with a list of { role, text }.
function M.fetch_history(session, cb)
	if not session then
		cb({})
		return
	end
	daemon.n = daemon.n + 1
	local tag = "h" .. daemon.n
	daemon.handlers[tag] = function(msg)
		if msg.type == "history" then
			daemon.handlers[tag] = nil
			cb(msg.messages or {})
		elseif msg.type == "error" then
			daemon.handlers[tag] = nil
			cb({})
		end
	end
	send_cmd({ cmd = "history", tag = tag, session = session, backend = M.backend() })
end

-- Fetch token/cost usage for a session; caches into M._usage and refreshes the rail.
function M.fetch_usage(session, cb)
	session = session or M.active_session
	if not session then
		if cb then
			cb(nil)
		end
		return
	end
	daemon.n = daemon.n + 1
	local tag = "u" .. daemon.n
	daemon.handlers[tag] = function(msg)
		if msg.type == "usage" then
			daemon.handlers[tag] = nil
			if not msg.error then
				M._usage = { cost = msg.cost, input = msg.input, output = msg.output, context = msg.context }
				pcall(M.render_rail)
			end
			if cb then
				cb(M._usage)
			end
		elseif msg.type == "error" then
			daemon.handlers[tag] = nil
			if cb then
				cb(nil)
			end
		end
	end
	send_cmd({ cmd = "usage", tag = tag, session = session, backend = M.backend() })
end

-- Compact (summarize) the active session so its context shrinks. Fire-and-forget with a toast.
function M.compact()
	local session = M.active_session
	if not session then
		M.toast("No active session to compact.")
		return
	end
	M.toast("Compacting session…")
	daemon.n = daemon.n + 1
	local tag = "c" .. daemon.n
	daemon.handlers[tag] = function(msg)
		if msg.type == "compacted" then
			daemon.handlers[tag] = nil
			M.toast("Session compacted.")
			M.fetch_usage(session)
		elseif msg.type == "error" then
			daemon.handlers[tag] = nil
			M.toast("Compaction failed: " .. tostring(msg.error))
		end
	end
	send_cmd({ cmd = "compact", tag = tag, session = session, backend = M.backend() })
end

-- ── Workpackages & sessions ─────────────────────────────────────
-- Hierarchy: a WORKPACKAGE is a named container for a chunk of work — it owns a
-- shared JOURNAL (context/brief across all its sessions) and a backlog. A SESSION
-- is one conversation thread inside a workpackage; a workpackage has MANY. Neither
-- exists without the other: a new workpackage is born with its first session, and a
-- new session is created inside the active workpackage. Switching = picking a
-- session (shown workpackage ▸ session); its workpackage comes with it. Each session
-- records the backend it runs on (opencode/claude ids can't cross-resume), so
-- selecting a session restores its backend.
--
-- manifest.json = {
--   active   = { wp = "<name>", key = "<session key>" },
--   packages = { ["<name>"] = { sessions = { {key,name,id,backend}, … } }, … },
-- }
local function wp_root()
	return vim.fn.getcwd() .. "/.tandem/wp"
end
local function wp_dir(name)
	return wp_root() .. "/" .. name
end
function M.wp_journal_path(name)
	return wp_dir(name or M.wp_active()) .. "/journal.md"
end
function M.wp_backlog_path(name)
	return wp_dir(name or M.wp_active()) .. "/backlog.md"
end

-- A fresh, unique session key (identity that survives before the backend hands us a
-- real session id — a new session has id=nil until its first turn).
local function new_key()
	M._keyn = (M._keyn or 0) + 1
	return "k" .. os.time() .. "_" .. M._keyn
end

-- Upgrade any older manifest shape (single pkg.session, per-backend session map, or a
-- string `active`) to the current { active={wp,key}, sessions=[…] } form.
local function normalize(m)
	if type(m) ~= "table" then
		m = {}
	end
	m.packages = type(m.packages) == "table" and m.packages or {}
	for name, pkg in pairs(m.packages) do
		if type(pkg) ~= "table" then
			pkg = {}
			m.packages[name] = pkg
		end
		local sess = pkg.sessions
		local is_array = type(sess) == "table" and (sess[1] ~= nil or next(sess) == nil)
		if not is_array then
			-- old per-backend MAP { opencode=…, claude=… }
			local arr = {}
			if type(sess) == "table" then
				for backend, id in pairs(sess) do
					if type(id) == "string" then
						arr[#arr + 1] = { key = new_key(), name = backend .. " session", id = id, backend = backend }
					end
				end
			end
			pkg.sessions = arr
		end
		if type(pkg.session) == "string" then -- oldest single-session field
			pkg.sessions[#pkg.sessions + 1] = { key = new_key(), name = "session", id = pkg.session, backend = "opencode" }
			pkg.session = nil
		end
		if #pkg.sessions == 0 then
			pkg.sessions[1] = { key = new_key(), name = "session 1", id = nil, backend = "opencode" }
		end
	end
	if not m.packages["default"] then
		m.packages["default"] = { sessions = { { key = new_key(), name = "session 1", id = nil, backend = "opencode" } } }
	end
	-- active pointer
	if type(m.active) == "string" then
		local wp = m.packages[m.active] and m.active or "default"
		m.active = { wp = wp, key = m.packages[wp].sessions[1].key }
	elseif type(m.active) ~= "table" or not m.active.wp or not m.packages[m.active.wp] then
		m.active = { wp = "default", key = m.packages["default"].sessions[1].key }
	end
	-- ensure the active key resolves to a real session in the active wp
	local sessions = m.packages[m.active.wp].sessions
	local found = false
	for _, e in ipairs(sessions) do
		if e.key == m.active.key then
			found = true
			break
		end
	end
	if not found then
		m.active.key = sessions[1].key
	end
	return m
end

local function wp_read_manifest()
	local p = wp_root() .. "/manifest.json"
	if vim.fn.filereadable(p) == 1 then
		local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(p), "\n"))
		if ok then
			return normalize(data)
		end
	end
	return normalize({})
end
local function wp_write_manifest(m)
	vim.fn.mkdir(wp_root(), "p")
	vim.fn.writefile({ vim.json.encode(m) }, wp_root() .. "/manifest.json")
end
local function wp_manifest()
	if not M._wp then
		M._wp = wp_read_manifest()
	end
	return M._wp
end

-- The active workpackage's name.
function M.wp_active()
	return wp_manifest().active.wp
end

-- The active session's entry table ({ key, name, id, backend }) within its workpackage.
local function active_entry(m)
	m = m or wp_manifest()
	for _, e in ipairs(m.packages[m.active.wp].sessions) do
		if e.key == m.active.key then
			return e
		end
	end
	return m.packages[m.active.wp].sessions[1]
end

-- The active session's display name (for the rail / pickers).
function M.session_name()
	local e = active_entry()
	return e and e.name or "session"
end

-- Make active_model match a backend (called when selecting a session so its thread
-- can actually be resumed on the backend it was created under).
function M._restore_backend(backend)
	if not backend or M.backend() == backend then
		return
	end
	for _, mo in ipairs(M.models) do
		if mo.backend == backend then
			M.active_model = mo
			return
		end
	end
end

-- Adopt the active session on startup: point M.active_session at its stored id and
-- restore its backend.
function M.wp_load()
	local e = active_entry()
	M.active_session = e and e.id or nil
	if e then
		M._restore_backend(e.backend)
	end
	pcall(M.ensure_journal) -- make sure the active workpackage has a journal doc
	M.rail_refresh()
end

-- The backend just handed us a real session id for the active (possibly brand-new)
-- session — record it (and the backend it belongs to) on the active entry.
function M.set_active_session(id)
	M.active_session = id
	local m = wp_manifest()
	local e = active_entry(m)
	if e then
		e.id = id
		e.backend = M.backend()
		wp_write_manifest(m)
	end
end

-- Create a NEW session inside the active workpackage (shares its journal/backlog).
-- Fresh thread: active_session = nil until its first turn. Uses the current backend.
function M.new_session(name)
	local m = wp_manifest()
	local sessions = m.packages[m.active.wp].sessions
	name = (name and vim.trim(name) ~= "" and vim.trim(name)) or ("session " .. (#sessions + 1))
	local key = new_key()
	sessions[#sessions + 1] = { key = key, name = name, id = nil, backend = M.backend() }
	m.active.key = key
	wp_write_manifest(m)
	M.active_session = nil
	M._usage = nil
	-- fresh session → clear the command centre's transcript if it's open
	if M._main and vim.api.nvim_buf_is_valid(M._main.conv_buf) then
		M.render_transcript(M._main, nil)
	end
	M.rail_refresh()
	vim.notify("Tandem: new session '" .. name .. "' in " .. m.active.wp)
end

-- Create a NEW workpackage — born with its first session — and switch to it.
function M.wp_create(name)
	name = name and vim.trim(name) or ""
	if name == "" then
		return
	end
	local m = wp_manifest()
	if m.packages[name] then
		vim.notify("Tandem: workpackage '" .. name .. "' already exists")
		return
	end
	local key = new_key()
	m.packages[name] = { sessions = { { key = key, name = "session 1", id = nil, backend = M.backend() } } }
	m.active = { wp = name, key = key }
	wp_write_manifest(m)
	vim.fn.mkdir(wp_dir(name), "p")
	pcall(M.ensure_journal, name) -- born with a journal to grow
	M.active_session = nil
	M._usage = nil
	M.rail_refresh()
	vim.notify("Tandem workpackage → " .. name)
end

-- Prompt for a name, then create a workpackage.
function M.wp_new()
	M.ask(function(name)
		M.wp_create(name)
	end, { title = " new workpackage name " })
end

-- Activate a specific session (by workpackage + key): load its id + backend.
function M.activate_session(wp, key)
	local m = wp_manifest()
	if not m.packages[wp] then
		return
	end
	local target
	for _, e in ipairs(m.packages[wp].sessions) do
		if e.key == key then
			target = e
			break
		end
	end
	if not target then
		return
	end
	m.active = { wp = wp, key = key }
	wp_write_manifest(m)
	M.active_session = target.id
	M._usage = nil
	M._restore_backend(target.backend)
	-- if the command centre is open, re-render it to show THIS session's conversation
	if M._main and vim.api.nvim_buf_is_valid(M._main.conv_buf) then
		M.render_transcript(M._main, M.active_session)
		M.fetch_usage(M.active_session)
	end
	M.rail_refresh()
	vim.notify("Tandem → " .. wp .. " ▸ " .. target.name)
end

-- Switch sessions via a hierarchy: every workpackage's sessions listed as
-- "workpackage ▸ session", plus shortcuts to add a session or a workpackage.
function M.session_pick()
	local m = wp_manifest()
	local names = {}
	for n in pairs(m.packages) do
		names[#names + 1] = n
	end
	table.sort(names)
	local items = {}
	for _, wp in ipairs(names) do
		for _, e in ipairs(m.packages[wp].sessions) do
			local active = (wp == m.active.wp and e.key == m.active.key)
			items[#items + 1] = {
				kind = "session",
				wp = wp,
				key = e.key,
				label = (active and "● " or "  ")
					.. wp
					.. "  ▸  "
					.. e.name
					.. "  ("
					.. (e.backend or "opencode")
					.. (e.id and "" or " · new")
					.. ")",
			}
		end
	end
	items[#items + 1] = { kind = "new_session", label = "＋ new session (in " .. m.active.wp .. ")" }
	items[#items + 1] = { kind = "new_wp", label = "＋ new workpackage…" }
	vim.ui.select(items, {
		prompt = "Switch session:",
		format_item = function(it)
			return it.label
		end,
	}, function(it)
		if not it then
			return
		end
		if it.kind == "session" then
			M.activate_session(it.wp, it.key)
		elseif it.kind == "new_session" then
			M.new_session()
		elseif it.kind == "new_wp" then
			M.wp_new()
		end
	end)
end

-- Switch to a session on `backend` within the active workpackage: reuse the most
-- recent one if present, else start a fresh session. Used when the picked model's
-- backend differs from the current session's (their ids can't cross-resume).
function M.switch_backend(backend)
	local m = wp_manifest()
	local sessions = m.packages[m.active.wp].sessions
	local pick
	for _, e in ipairs(sessions) do
		if (e.backend or "opencode") == backend then
			pick = e -- last match wins = most recent
		end
	end
	if pick then
		M.activate_session(m.active.wp, pick.key)
	else
		M.new_session() -- uses M.backend() = the just-selected model's backend
	end
end

-- Rename the active session.
function M.session_rename()
	local e = active_entry()
	local old = e and e.name or "session"
	M.ask(function(new)
		new = vim.trim(new)
		if new == "" or new == old then
			return
		end
		local m = wp_manifest()
		active_entry(m).name = new
		wp_write_manifest(m)
		M.rail_refresh()
		vim.notify("Renamed session → " .. new)
	end, { title = " rename session '" .. old .. "' to " })
end

-- Rename the active workpackage (moves its journal/backlog dir with it).
function M.wp_rename()
	local old = M.wp_active()
	M.ask(function(new)
		new = vim.trim(new)
		if new == "" or new == old then
			return
		end
		local m = wp_manifest()
		if m.packages[new] then
			vim.notify("Tandem: workpackage '" .. new .. "' already exists")
			return
		end
		m.packages[new] = m.packages[old]
		m.packages[old] = nil
		if m.active.wp == old then
			m.active.wp = new
		end
		wp_write_manifest(m)
		pcall(os.rename, wp_dir(old), wp_dir(new))
		M.rail_refresh()
		vim.notify("Renamed workpackage → " .. new)
	end, { title = " rename workpackage '" .. old .. "' to " })
end

-- The active workpackage's journal (its brief/plan/decisions), injected as context.
function M.read_journal()
	local path = M.wp_journal_path()
	if vim.fn.filereadable(path) == 0 then
		return ""
	end
	return table.concat(vim.fn.readfile(path), "\n")
end

-- Append an entry to the active workpackage's journal under a timestamped heading.
function M.journal_append(entry)
	local path = M.wp_journal_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local lines = { "", "## " .. os.date("%Y-%m-%d %H:%M") }
	for _, l in ipairs(vim.split(entry, "\n", { plain = true })) do
		lines[#lines + 1] = l
	end
	vim.fn.writefile(lines, path, "a") -- the "a" flag = append, don't overwrite
	vim.notify("Journaled ✎")
end

-- Jot a quick note into the journal (reuses the input bubble you built earlier).
function M.journal_note()
	M.ask(function(note)
		if note ~= "" then
			M.journal_append(note)
		end
	end)
end

-- Write `lines` to `path`, updating any OPEN buffer for it too (so the AI writing
-- the journal/backlog doesn't silently diverge from a copy you have open — the same
-- hazard as on_edit). Creates the dir as needed.
local function write_doc(path, lines)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	pcall(function()
		vim.api.nvim_buf_call(buf, function()
			vim.cmd("silent keepalt noautocmd write")
		end)
	end)
end

-- The default journal template (the living-brief sections the AI curates).
function M.journal_template()
	return { "# Journal", "", "## Goal", "", "## Current state", "", "## Key decisions", "", "## Approach & constraints", "" }
end

-- Seed a workpackage's journal with the template if it doesn't exist yet (called when
-- a workpackage is created / adopted, so there's structure for the AI + you to grow).
function M.ensure_journal(name)
	local path = M.wp_journal_path(name)
	if vim.fn.filereadable(path) == 0 then
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		vim.fn.writefile(M.journal_template(), path)
	end
end

-- The agent's tandem_journal tool: REPLACE the workpackage journal with a freshly
-- curated brief (the AI keeps it concise — goal / state / decisions / approach).
function M.on_journal(msg)
	local content = msg.content or ""
	if vim.trim(content) == "" then
		return
	end
	write_doc(M.wp_journal_path(), vim.split(content, "\n", { plain = true }))
	M.toast("✎ journal updated — <leader>lj to view")
end

-- Mark backlog items done by matching their text (used by tandem_backlog complete).
function M.backlog_complete(texts)
	local path = M.wp_backlog_path()
	if vim.fn.filereadable(path) == 0 then
		return
	end
	local want = {}
	for _, t in ipairs(texts or {}) do
		want[vim.trim(t):lower()] = true
	end
	local lines = vim.fn.readfile(path)
	for i, l in ipairs(lines) do
		local text = l:match("^%s*%- %[ %]%s*(.*)$")
		if text and want[vim.trim(text):lower()] then
			lines[i] = (l:gsub("%[ %]", "[x]", 1))
		end
	end
	write_doc(path, lines)
	M.rail_refresh()
end

-- The agent's tandem_backlog tool: add new tasks and/or tick off finished ones. We
-- never rewrite the whole list (so your ordering + manual edits are preserved).
function M.on_backlog(msg)
	if msg.add then
		for _, t in ipairs(msg.add) do
			M.backlog_add(t)
		end
	end
	if msg.complete then
		M.backlog_complete(msg.complete)
	end
	M.toast("✎ backlog updated")
end

-- View the active workpackage's journal in an editable markdown float.
function M.view_journal()
	local path = M.wp_journal_path()
	if vim.fn.filereadable(path) == 0 then
		write_doc(path, M.journal_template())
	end
	local W = math.floor(vim.o.columns * 0.6)
	local H = math.floor(vim.o.lines * 0.7)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.bo[buf].filetype = "markdown"
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor", row = math.floor((vim.o.lines - H) / 2), col = math.floor((vim.o.columns - W) / 2),
		width = W, height = H, style = "minimal", border = "rounded",
		title = " journal · " .. M.wp_active() .. " · q saves ",
		title_pos = "center",
	})
	vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].conceallevel = true, true, 2
	vim.wo[win].winhighlight = "FloatBorder:TandemBorderActive"
	vim.keymap.set("n", "q", function()
		pcall(function() vim.cmd("silent keepalt noautocmd write") end)
		pcall(vim.api.nvim_win_close, win, true)
	end, { buffer = buf })
end

-- Explicit trigger: ask the current session to update the journal + backlog from the
-- conversation so far (the "capture plan" escape hatch — the AI also does this
-- ambiently per the agent files, but you can always force it).
function M.capture_plan()
	if not M.active_session then
		vim.notify("Tandem: no active session to capture from")
		return
	end
	M.toast("✎ capturing our plan into the journal + backlog…")
	local journal = M.read_journal()
	local current = journal ~= "" and ("Here is the workpackage's CURRENT journal:\n\n" .. journal .. "\n\n") or ""
	M.run(
		M.active_session,
		current
			.. "Update this workpackage's shared memory from our conversation so far. Call tandem_journal "
			.. "with the COMPLETE updated brief (goal, current state, key decisions, approach & constraints): "
			.. "KEEP the existing content that still holds — especially decisions and context that aren't in "
			.. "this conversation — MERGE in what we've just discussed, and prune only what's genuinely outdated. "
			.. "Do NOT rewrite from scratch or drop prior context. Then call tandem_backlog to add any concrete "
			.. "new tasks. Keep the journal tight — it's injected into every session."
	)
end

-- ── @-references (pull files into a prompt) ─────────────────────
-- Repo files for the @ picker (tracked files; falls back to a find).
function M.repo_files()
	local files = vim.fn.systemlist({ "git", "ls-files" })
	if vim.v.shell_error ~= 0 or #files == 0 then
		files = vim.fn.systemlist({ "find", ".", "-type", "f", "-not", "-path", "*/.git/*", "-not", "-path", "*/node_modules/*" })
		for i, f in ipairs(files) do
			files[i] = (f:gsub("^%./", ""))
		end
	end
	return files
end

-- Pick a file to reference; cb(path_or_nil).
function M.pick_reference(cb)
	vim.ui.select(M.repo_files(), { prompt = "@ reference a file:" }, cb)
end

-- Resolve @path references in a prompt: prepend each referenced file's content so the
-- AI actually sees it. Leaves the @path in the text as a marker.
function M.resolve_refs(text)
	local extra, seen = {}, {}
	for ref in text:gmatch("@([%w%._%-/]+)") do
		if not seen[ref] then
			seen[ref] = true
			local path = ref:match("^/") and ref or (vim.fn.getcwd() .. "/" .. ref)
			if vim.fn.filereadable(path) == 1 then
				extra[#extra + 1] = "File @" .. ref .. ":\n" .. table.concat(vim.fn.readfile(path), "\n")
			end
		end
	end
	if #extra == 0 then
		return text
	end
	return table.concat(extra, "\n\n") .. "\n\n" .. text
end

-- ── Backlog (per-workpackage, priority-ordered tasks) ───────────
-- Parse the active workpackage's backlog.md into { done, text, lnum } (file order
-- = priority order). Stored as a markdown checklist so it's hand-editable.
function M.backlog_parse()
	local path = M.wp_backlog_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local items = {}
	for i, l in ipairs(vim.fn.readfile(path)) do
		local mark, text = l:match("^%s*%- %[([ xX])%]%s*(.*)$")
		if mark then
			items[#items + 1] = { done = (mark ~= " "), text = text, lnum = i }
		end
	end
	return items
end

-- Append a task to the active workpackage's backlog.
function M.backlog_add(text)
	text = text and vim.trim(text) or ""
	if text == "" then
		return
	end
	local path = M.wp_backlog_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	if vim.fn.filereadable(path) == 0 then
		vim.fn.writefile({ "# Backlog", "" }, path)
	end
	vim.fn.writefile({ "- [ ] " .. text }, path, "a")
	M.rail_refresh()
	vim.notify("Backlog + " .. text)
end

-- Jot a backlog item via the input bubble.
function M.backlog_note()
	M.ask(function(t)
		M.backlog_add(t)
	end, { title = " new backlog item " })
end

-- Open the full backlog: a real markdown buffer you edit / reorder / check off.
-- <CR> toggles done · <M-j>/<M-k> move the line · q saves + closes.
function M.backlog()
	local path = M.wp_backlog_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	if vim.fn.filereadable(path) == 0 then
		vim.fn.writefile({ "# Backlog", "", "- [ ] write tasks here — top line = highest priority" }, path)
	end
	local W = math.floor(vim.o.columns * 0.6)
	local H = math.floor(vim.o.lines * 0.7)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.bo[buf].filetype = "markdown"
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor", row = math.floor((vim.o.lines - H) / 2), col = math.floor((vim.o.columns - W) / 2),
		width = W, height = H, style = "minimal", border = "rounded",
		title = " backlog · " .. M.wp_active() .. " · <CR> toggle · M-j/M-k move · q save ",
		title_pos = "center",
	})
	vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].conceallevel = true, true, 2
	vim.wo[win].winhighlight = "FloatBorder:TandemBorderActive"
	vim.keymap.set("n", "<CR>", function()
		local l = vim.api.nvim_get_current_line()
		if l:match("^%s*%- %[ %]") then
			l = l:gsub("%- %[ %]", "- [x]", 1)
		elseif l:match("^%s*%- %[[xX]%]") then
			l = l:gsub("%- %[[xX]%]", "- [ ]", 1)
		end
		vim.api.nvim_set_current_line(l)
	end, { buffer = buf })
	vim.keymap.set("n", "<M-j>", "<cmd>silent! move +1<cr>", { buffer = buf })
	vim.keymap.set("n", "<M-k>", "<cmd>silent! move -2<cr>", { buffer = buf })
	vim.keymap.set("n", "q", function()
		pcall(function()
			vim.cmd("silent write")
		end)
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		M.rail_refresh()
	end, { buffer = buf })
end

-- Planning: turn a goal (+ the journal brief) into a prioritized backlog via the AI,
-- appended to the active workpackage's backlog. Also the "manual setup" command.
function M.plan()
	M.ask(function(goal)
		goal = vim.trim(goal or "")
		local journal = M.read_journal()
		local prompt = (journal ~= "" and ("Project brief:\n" .. journal .. "\n\n") or "")
			.. "Goal: "
			.. (goal ~= "" and goal or "(plan the next steps for the brief above)")
			.. "\n\nBreak this into a PRIORITIZED backlog of concrete, actionable tasks (highest priority "
			.. "first). Reply with ONLY a markdown checklist — one task per line:\n- [ ] first task\n- [ ] second task"
		local acc = ""
		vim.notify("Tandem: planning the backlog…")
		M.prompt(nil, prompt, function(msg)
			if msg.type == "delta" then
				acc = acc .. msg.text
			elseif msg.type == "done" then
				local tasks = {}
				for line in (acc .. "\n"):gmatch("(.-)\n") do
					local t = line:match("^%s*%- %[[ xX]%]%s*(.+)$") or line:match("^%s*[%-%*]%s+(.+)$")
					if t then
						tasks[#tasks + 1] = vim.trim((t:gsub("^%[[ xX]%]%s*", "")))
					end
				end
				if #tasks == 0 then
					vim.notify("Tandem: couldn't parse a backlog from the reply")
					return
				end
				for _, t in ipairs(tasks) do
					M.backlog_add(t)
				end
				vim.notify("Tandem: added " .. #tasks .. " tasks to the backlog")
				M.backlog()
			end
		end, false, { agent = "plan", tools = { write = false, edit = false, patch = false } })
	end, { title = " plan: what's the goal? " })
end

-- ── Toasts (bottom-screen notifications) ────────────────────────
local toast_win = nil

function M.toast_dismiss()
	if toast_win and vim.api.nvim_win_is_valid(toast_win) then
		vim.api.nvim_win_close(toast_win, true)
	end
	toast_win = nil
end

-- Show a small notification at the bottom-right; auto-dismisses.
function M.toast(text, opts)
	opts = opts or {}
	M.toast_dismiss()
	local lines = vim.split(text, "\n", { plain = true })
	local maxw = 0
	for _, l in ipairs(lines) do
		maxw = math.max(maxw, vim.fn.strdisplaywidth(l))
	end
	local width = math.min(maxw + 2, 70)
	-- expand vertically to fit the WRAPPED text (long lines wrap to several rows)
	local rows = 0
	for _, l in ipairs(lines) do
		rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
	end
	local height = math.max(1, math.min(rows, vim.o.lines - 4))
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		anchor = "SW",
		row = vim.o.lines - 2,
		col = math.max(0, math.floor((vim.o.columns - width) / 2)), -- centered
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		focusable = false,
		title = opts.title or " tandem ",
		title_pos = "center",
		noautocmd = true,
	})
	vim.wo[win].wrap = true
	toast_win = win
	if not opts.sticky then -- sticky toasts stay until dismissed/answered
		vim.defer_fn(function()
			if toast_win == win then
				M.toast_dismiss()
			end
		end, opts.timeout or 4500)
	end
	return win
end

-- ── Activity indicator (spinner while the AI is working) ─────────
local activity = { n = 0, win = nil, timer = nil, frame = 1, label = nil }
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function activity_render()
	local text = SPINNER[activity.frame] .. " " .. (activity.label or "tandem working…")
	local width = math.min(vim.fn.strdisplaywidth(text), vim.o.columns - 2)
	if activity.win and vim.api.nvim_win_is_valid(activity.win) then
		vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(activity.win), 0, -1, false, { text })
		-- resize so a longer status line isn't clipped (and re-anchor top-right)
		vim.api.nvim_win_set_config(activity.win, {
			relative = "editor", anchor = "NE", row = 0, col = vim.o.columns, width = width, height = 1,
		})
	else
		local b = vim.api.nvim_create_buf(false, true)
		vim.bo[b].bufhidden = "wipe"
		vim.api.nvim_buf_set_lines(b, 0, -1, false, { text })
		activity.win = vim.api.nvim_open_win(b, false, {
			relative = "editor",
			anchor = "NE",
			row = 0,
			col = vim.o.columns,
			width = width,
			height = 1,
			style = "minimal",
			focusable = false,
			noautocmd = true,
		})
	end
end

-- Update the one-line status the AI pushes (thinking / reading X / writing Y / …).
function M.on_status(msg)
	activity.label = msg.label
	if activity.win and vim.api.nvim_win_is_valid(activity.win) then
		activity_render() -- only repaint if the indicator is up
	end
end

function M.activity_reset()
	activity.n = 0
	if activity.timer then
		vim.fn.timer_stop(activity.timer)
		activity.timer = nil
	end
	if activity.win and vim.api.nvim_win_is_valid(activity.win) then
		vim.api.nvim_win_close(activity.win, true)
	end
	activity.win = nil
	activity.label = nil
end

function M.activity_start()
	activity.n = activity.n + 1
	if not activity.timer then
		activity.frame = 1
		activity.label = "thinking…" -- until the first status event arrives
		activity_render()
		activity.timer = vim.fn.timer_start(110, function()
			activity.frame = (activity.frame % #SPINNER) + 1
			activity_render()
		end, { ["repeat"] = -1 })
	end
end

function M.activity_stop()
	activity.n = math.max(0, activity.n - 1)
	if activity.n == 0 then
		M.activity_reset()
	end
end

-- Send `text` to a session. Questions / narration / edits all arrive out-of-band via
-- the tandem_* tools (→ on_ask / on_notify / on_edit), so there's nothing to parse
-- from the reply text here.
function M.run(session, text)
	M.prompt(session, text, function(msg)
		if msg.type == "session" then
			M.set_active_session(msg.id)
		end
	end)
end

-- ── Pairing modes (role / level / coach) ────────────────────────
local AGENTS = PLUGIN_ROOT .. "/agents/"

local function read_file(path)
	if vim.fn.filereadable(path) == 0 then
		return ""
	end
	return table.concat(vim.fn.readfile(path), "\n")
end

M.role = "neutral" -- "neutral" | "navigator" | "driver"
M.level = "medium" -- navigator → guidance level; driver → autonomy level
M.coach = false -- Socratic overlay, layerable over any role/level
M.follow = false -- when ON, jump to & watch the AI's edits live (else type off-screen)

local LEVEL_TEXT = {
	navigator = {
		high = "Guidance level: HIGH — keep every direction (tandem_instruct) very high-level and conceptual: name the goal or the approach, not the steps. e.g. 'add input validation to the form'. Let the human work out the how.",
		medium = "Guidance level: MEDIUM — give the key steps but not every detail: outline the moving parts. e.g. 'validate each field, then show errors next to the inputs'.",
		low = "Guidance level: LOW — be granular and exact in each direction: tell them precisely what to do, step by step, down to specific names, signatures, and lines. e.g. 'in utils.lua add a function reverse(list) that loops from #list down to 1'.",
	},
	driver = {
		high = "Autonomy: HIGH — work autonomously. Minimal chatter: at most one tandem_notify at the end. Rarely use tandem_ask.",
		medium = "Autonomy: MEDIUM — a short tandem_notify at each significant step; use tandem_ask only for genuine decisions.",
		low = "Autonomy: LOW — narrate each significant change with tandem_notify, and use tandem_ask before ANY naming or structural choice (function/variable/file names, how to structure something) — stop and wait for the answer.",
	},
}

-- Assemble the system prompt for the current mode from the agent markdown files.
function M.build_system()
	local parts = { read_file(AGENTS .. M.role .. ".md") }
	local lvl = LEVEL_TEXT[M.role] and LEVEL_TEXT[M.role][M.level]
	if lvl then
		parts[#parts + 1] = lvl
	end
	if M.coach then
		parts[#parts + 1] = read_file(AGENTS .. "coach.md")
	end
	return table.concat(parts, "\n\n")
end

function M.pick_role()
	vim.ui.select({ "neutral", "navigator", "driver" }, { prompt = "Tandem role:" }, function(r)
		if r then
			M.role = r
			vim.notify("Tandem role → " .. r)
			M.rail_refresh()
		end
	end)
end

function M.pick_level()
	-- Level's MEANING depends on the mode: navigator = guidance grain, driver = autonomy.
	if not LEVEL_TEXT[M.role] then
		vim.notify("Tandem: '" .. M.role .. "' mode has no level — pick navigator or driver")
		return
	end
	vim.ui.select({ "high", "medium", "low" }, {
		prompt = (M.role == "navigator" and "Guidance" or "Autonomy") .. " level:",
	}, function(l)
		if l then
			M.level = l
			vim.notify("Tandem level → " .. l)
			M.rail_refresh()
		end
	end)
end

function M.toggle_coach()
	M.coach = not M.coach
	vim.notify("Tandem coach → " .. (M.coach and "on" or "off"))
	M.rail_refresh()
end

-- Follow: when ON, the AI's edits open and jump you to the file so you watch it
-- type live (the chat is closed if it's covering your code). When OFF, edits type
-- off-screen and a toast offers <leader>lg to follow manually.
function M.toggle_follow()
	M.follow = not M.follow
	vim.notify("Tandem follow → " .. (M.follow and "on" or "off"))
	M.rail_refresh()
end

-- Pick the role, then (for navigator/driver) immediately CASCADE into its level.
-- This is the "choose the mode and you're made to set the sub-setting too" flow.
function M.pick_mode()
	vim.ui.select({ "neutral", "navigator", "driver" }, { prompt = "Tandem mode:" }, function(r)
		if not r then
			return
		end
		M.role = r
		if LEVEL_TEXT[r] then -- navigator / driver have a level; neutral doesn't
			local label = (r == "navigator") and "Guidance level:" or "Autonomy level:"
			vim.ui.select({ "high", "medium", "low" }, { prompt = label }, function(l)
				if l then
					M.level = l
				end
				vim.notify("Tandem → " .. r .. (l and (" / " .. l) or ""))
				M.rail_refresh()
			end)
		else
			vim.notify("Tandem → " .. r)
			M.rail_refresh()
		end
	end)
end

-- The master settings menu: pick a setting, its (possibly cascading) selector opens.
-- Vim navigation + Enter come free from vim.ui.select; no bespoke window needed.
function M.settings_menu()
	local items = {
		{ label = "Mode", run = M.pick_mode },
		{ label = "Level", run = M.pick_level },
		{ label = "Model", run = M.pick_model },
		{ label = "Coach (toggle)", run = M.toggle_coach },
		{ label = "Follow (toggle)", run = M.toggle_follow },
		{ label = "Typing pace", run = M.pick_granularity },
		{ label = "Switch session", run = M.session_pick },
		{ label = "New session", run = M.new_session },
		{ label = "Rename session", run = M.session_rename },
		{ label = "Compact conversation", run = M.compact },
		{ label = "New workpackage", run = M.wp_new },
		{ label = "Rename workpackage", run = M.wp_rename },
		{ label = "View journal", run = M.view_journal },
		{ label = "Jot journal note", run = M.journal_note },
		{ label = "Capture plan → journal + backlog (AI)", run = M.capture_plan },
		{ label = "Open backlog", run = M.backlog },
		{ label = "Plan backlog (AI)", run = M.plan },
		{ label = "Restart daemon", run = M.restart_daemon },
	}
	vim.ui.select(items, {
		prompt = "Tandem settings:",
		format_item = function(it)
			return it.label
		end,
	}, function(it)
		if it then
			it.run()
		end
	end)
end

-- Ask the Navigator for the next instruction; it surfaces as a sticky toast.
function M.next_instruction()
	if not M.active_session then
		vim.notify("Tandem: no active session")
		return
	end
	M.run(M.active_session, "What is the next instruction? Keep it to one step.")
end

-- ── Attribute rail (read-only labels in the command centre's right pane) ──
-- A pure display of current state. You never edit IN here — editing happens
-- through the selectors (settings_menu / the per-setting keybinds), so the rail
-- can never drift out of sync. Top half = settings; bottom = the backlog panel.
-- Render the attribute rail. `show_backlog` (default true) controls the backlog
-- panel — the command centre shows it; bubbles want settings only.
function M.render_rail(buf, show_backlog)
	if show_backlog == nil then
		show_backlog = true
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	-- collapse a (possibly multi-line) item to one line that fits the rail width
	local function fit(s, w)
		s = vim.trim((s:gsub("%s+", " ")))
		if vim.fn.strdisplaywidth(s) <= w then
			return s
		end
		while #s > 0 and vim.fn.strdisplaywidth(s) > w - 1 do
			s = s:sub(1, -2)
		end
		return s .. "…"
	end
	local lines = {
		"",
		"  ⚙  SETTINGS",
		"",
		"  Mode     " .. M.role,
	}
	if LEVEL_TEXT[M.role] then -- neutral has no level
		lines[#lines + 1] = "  Level    " .. M.level
	end
	lines[#lines + 1] = "  Coach    " .. (M.coach and "on" or "off")
	lines[#lines + 1] = "  Follow   " .. (M.follow and "on" or "off")
	lines[#lines + 1] = "  Model    " .. (M.active_model and M.active_model.label or "?")
	lines[#lines + 1] = "  Backend  " .. M.backend()
	lines[#lines + 1] = "  Pace     " .. M.granularity
	local wp_name, sess_name = "default", "session"
	pcall(function()
		wp_name = M.wp_active()
		sess_name = M.session_name()
	end)
	lines[#lines + 1] = "  Package  " .. fit(wp_name, 22)
	lines[#lines + 1] = "  Session  " .. fit(sess_name .. (M.active_session and "" or "  · new"), 22)
	if M._usage then -- context size + spend for the active session
		local u = M._usage
		local ctx = u.context or 0
		local ctx_s = ctx >= 1000 and (string.format("%.1fk", ctx / 1000)) or tostring(ctx)
		lines[#lines + 1] = "  Context  " .. ctx_s
		lines[#lines + 1] = "  Cost     $" .. string.format("%.4f", u.cost or 0)
	end
	if show_backlog then -- the command centre shows the workpackage backlog (top few)
		lines[#lines + 1] = ""
		lines[#lines + 1] = "  ──────────────"
		lines[#lines + 1] = ""
		local items = M.backlog_parse()
		local open = 0
		for _, it in ipairs(items) do
			if not it.done then
				open = open + 1
			end
		end
		lines[#lines + 1] = "  🗒  BACKLOG" .. (open > 0 and ("  (" .. open .. ")") or "")
		lines[#lines + 1] = ""
		if #items == 0 then
			lines[#lines + 1] = "  (empty — <leader>lb)"
		else
			local shown = 0
			for _, it in ipairs(items) do -- priority order = file order
				if not it.done then
					lines[#lines + 1] = "  ☐ " .. fit(it.text, 22)
					shown = shown + 1
					if shown >= 6 then
						break
					end
				end
			end
			if shown == 0 then
				lines[#lines + 1] = "  ✓ all done"
			end
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ""
	lines[#lines + 1] = "  Tab  switch pane"
	lines[#lines + 1] = "  ?    settings"
	lines[#lines + 1] = "  q    close"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

-- Re-render the rail if the command centre is open (settings changed elsewhere).
function M.rail_refresh()
	if M._rail_buf and vim.api.nvim_buf_is_valid(M._rail_buf) then
		M.render_rail(M._rail_buf, M._rail_todo)
	end
end

-- ── Main chat window (central command centre) ───────────────────
-- The full-size panel, tied to the ACTIVE working session — for planning, general
-- conversation, history, and session/attribute management. Same shape as the bubbles.
-- Clear a panel's transcript and re-render a session's prior messages into it (user
-- messages as grey blocks, assistant plain). Used on open AND when the active session
-- changes, so the main window always reflects the session you're looking at.
function M.render_transcript(P, session)
	if not (P and vim.api.nvim_buf_is_valid(P.conv_buf)) then
		return
	end
	vim.api.nvim_buf_set_lines(P.conv_buf, 0, -1, false, {}) -- clear old transcript
	vim.api.nvim_buf_clear_namespace(P.conv_buf, chat_ns, 0, -1) -- and its user-msg highlights
	M.fetch_history(session, function(messages)
		if not vim.api.nvim_buf_is_valid(P.conv_buf) or #messages == 0 then
			return
		end
		for _, m in ipairs(messages) do
			local txt = vim.trim(m.text or "")
			if txt ~= "" then
				if m.role == "user" then
					P.append_user(txt)
				else
					local lines = vim.split(txt, "\n", { plain = true })
					lines[#lines + 1] = ""
					P.append(lines)
				end
			end
		end
	end)
end

function M.open_chat()
	local P = make_panel(centre_box(), "tandem · conversation")
	M._main = P -- the command centre; session switches re-render its transcript

	vim.fn.prompt_setcallback(P.input_buf, function(input)
		if input == "" then
			return
		end
		vim.schedule(function() -- keep the input box clean
			if vim.api.nvim_buf_is_valid(P.input_buf) then
				local n = vim.api.nvim_buf_line_count(P.input_buf)
				if n > 1 then
					pcall(vim.api.nvim_buf_set_lines, P.input_buf, 0, n - 1, false, {})
				end
			end
		end)

		local text = input
		if M.active_session == nil then -- inject the journal on a fresh session
			local journal = M.read_journal()
			if journal ~= "" then
				text = "Project journal (what we're working on):\n" .. journal .. "\n\n" .. input
			end
		end

		panel_turn(P, M.active_session, input, text, function(id)
			M.set_active_session(id)
			M.rail_refresh()
		end)
	end)

	-- render the session's prior messages into the transcript on open
	M.render_transcript(P, M.active_session)

	-- pull token/cost usage for the active session into the rail
	M.fetch_usage(M.active_session)

	P.focus_input()
end

-- ── Review mode (walk the AI's uncommitted changes) ─────────────
-- `review` builds a quickfix list from the uncommitted git hunks so you can walk the
-- changes immediately (no AI). `review_summaries` is a separate, explicit call that
-- has the AI explain each hunk; summaries are cached by hunk content (so re-entering
-- shows the same ones, but new/changed hunks regenerate). A float shows the current
-- hunk's summary as you step through with :cnext / :cprev.
M._review_cache = M._review_cache or {} -- hunk hash -> summary (persists across reviews)
M._review_hunks = nil
M._review_active = false
local review_box = nil
local review_last = nil

local function cwd_git_root()
	local root = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })[1]
	if vim.v.shell_error ~= 0 or not root or root == "" then
		return nil
	end
	return root
end

-- Uncommitted changes as hunks: tracked (git diff HEAD -U0) + untracked (new) files.
local function git_hunks(root)
	local hunks = {}
	local out = vim.fn.systemlist({ "git", "-C", root, "diff", "HEAD", "--no-color", "-U0" })
	local file, i = nil, 1
	while i <= #out do
		local line = out[i]
		local f = line:match("^%+%+%+ b/(.+)$")
		if f then
			file = f
		elseif line:match("^diff %-%-git") then
			file = nil
		elseif file then
			local start = line:match("^@@ %-%d+,?%d* %+(%d+)")
			if start then
				local body, j = { line }, i + 1
				while j <= #out and not out[j]:match("^@@") and not out[j]:match("^diff %-%-git") do
					body[#body + 1] = out[j]
					j = j + 1
				end
				local diff = table.concat(body, "\n")
				local lnum = math.max(1, tonumber(start))
				hunks[#hunks + 1] = {
					file = root .. "/" .. file,
					lnum = lnum,
					diff = diff,
					hash = vim.fn.sha256(file .. "\n" .. diff),
					label = (file:match("[^/]+$") or file) .. ":" .. lnum,
				}
				i = j - 1
			end
		end
		i = i + 1
	end
	local untracked = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
	if vim.v.shell_error == 0 then
		for _, f in ipairs(untracked) do
			if f ~= "" then
				local path = root .. "/" .. f
				local ok, content = pcall(function()
					return table.concat(vim.fn.readfile(path), "\n")
				end)
				content = ok and content or ""
				hunks[#hunks + 1] = {
					file = path,
					lnum = 1,
					diff = "(new file)\n" .. content,
					hash = vim.fn.sha256(f .. "\n" .. content),
					label = (f:match("[^/]+$") or f) .. " (new)",
				}
			end
		end
	end
	return hunks
end

local function qf_text(h)
	local sum = M._review_cache[h.hash]
	if sum then
		return "✎ " .. vim.trim((sum:gsub("%s+", " "))):sub(1, 90)
	end
	return "~ " .. h.label
end

local function review_current_hunk()
	if not M._review_hunks then
		return nil
	end
	local name = vim.api.nvim_buf_get_name(0)
	local row = vim.api.nvim_win_get_cursor(0)[1]
	local best
	for _, h in ipairs(M._review_hunks) do
		if h.file == name and row >= h.lnum and (not best or h.lnum > best.lnum) then
			best = h
		end
	end
	return best
end

local function review_box_close()
	if review_box and vim.api.nvim_win_is_valid(review_box) then
		vim.api.nvim_win_close(review_box, true)
	end
	review_box, review_last = nil, nil
end

-- Show the current hunk's cached summary in a float above the cursor (if generated).
function M.review_show_summary()
	local h = review_current_hunk()
	local sum = h and M._review_cache[h.hash]
	if not sum then
		review_box_close()
		return
	end
	if review_last == h.hash and review_box and vim.api.nvim_win_is_valid(review_box) then
		return -- already showing this hunk
	end
	review_box_close()
	local lines = vim.split(sum, "\n", { plain = true })
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l))
	end
	width = math.min(math.max(width + 2, 30), 72)
	-- expand vertically to fit the WRAPPED text (a long line wraps to several rows)
	local rows = 0
	for _, l in ipairs(lines) do
		rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
	end
	local height = math.max(1, math.min(rows, vim.o.lines - 4))
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	review_box = vim.api.nvim_open_win(buf, false, {
		relative = "cursor", anchor = "SW", row = 0, col = 2,
		width = width, height = height,
		style = "minimal", border = "rounded",
		title = " why ", title_pos = "center",
		focusable = false, noautocmd = true,
	})
	vim.wo[review_box].wrap = true
	vim.wo[review_box].winhighlight = "FloatBorder:TandemBorderActive"
	review_last = h.hash
end

-- Enter review: build the quickfix list from the uncommitted hunks and start walking.
function M.review()
	local root = cwd_git_root()
	if not root then
		vim.notify("Tandem review: needs a git repo")
		return
	end
	local hunks = git_hunks(root)
	if #hunks == 0 then
		vim.notify("Tandem review: no uncommitted changes")
		return
	end
	M._review_hunks = hunks
	local items = {}
	for _, h in ipairs(hunks) do
		items[#items + 1] = { filename = h.file, lnum = h.lnum, text = qf_text(h) }
	end
	vim.fn.setqflist({}, "r", { title = "Tandem review", items = items })
	vim.cmd("copen")
	pcall(vim.cmd, "cfirst")
	M._review_active = true
	local grp = vim.api.nvim_create_augroup("TandemReview", { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = grp,
		callback = function()
			if M._review_active then
				M.review_show_summary()
			end
		end,
	})
	vim.notify(string.format("Tandem review: %d change%s — :cnext/:cprev to walk", #hunks, #hunks > 1 and "s" or ""))
	M.review_show_summary()
end

-- Explain each hunk (a separate, explicit model call). Regenerates the full set so
-- new uncommitted work is picked up; cached by hunk content otherwise.
function M.review_summaries()
	local hunks = M._review_hunks
	if not hunks or #hunks == 0 then
		vim.notify("Tandem review: run review first")
		return
	end
	local parts = {
		"You are reviewing changes made to this project. For EACH numbered hunk below,",
		"explain in 2-4 sentences WHAT it changes and WHY. Ground it ONLY in the diff.",
		"Reply using EXACTLY this format and nothing else:",
		"<<HUNK 1>>",
		"explanation…",
		"<<HUNK 2>>",
		"explanation…",
		"",
		"The hunks:",
		"",
	}
	for i, h in ipairs(hunks) do
		parts[#parts + 1] = "<<HUNK " .. i .. ">> (" .. h.label .. ")\n" .. h.diff .. "\n"
	end
	local acc = ""
	vim.notify("Tandem review: generating summaries…")
	M.prompt(nil, table.concat(parts, "\n"), function(msg)
		if msg.type == "delta" then
			acc = acc .. msg.text
		elseif msg.type == "done" then
			local text = acc .. "\n<<HUNK 0>>"
			local marks = {}
			for pos, num in text:gmatch("()<<HUNK%s+(%d+)>>") do
				marks[#marks + 1] = { pos = pos, num = tonumber(num) }
			end
			for k = 1, #marks - 1 do
				local m = marks[k]
				local bstart = text:find(">>", m.pos, true) + 2
				local body = vim.trim(text:sub(bstart, marks[k + 1].pos - 1))
				local h = hunks[m.num]
				if h and body ~= "" then
					M._review_cache[h.hash] = body
				end
			end
			if M._review_active then
				local items = {}
				for _, h in ipairs(hunks) do
					items[#items + 1] = { filename = h.file, lnum = h.lnum, text = qf_text(h) }
				end
				vim.fn.setqflist({}, "r", { title = "Tandem review", items = items })
			end
			review_last = nil
			M.review_show_summary()
			vim.notify("Tandem review: summaries ready")
		end
	end, false, {
		system = "You explain code changes concisely and accurately, grounded ONLY in the diff shown. Do not use tools or write files.",
		agent = "plan",
		tools = { write = false, edit = false, patch = false },
	})
end

function M.review_exit()
	M._review_active = false
	M._review_hunks = nil
	review_box_close()
	pcall(vim.api.nvim_del_augroup_by_name, "TandemReview")
	pcall(vim.cmd, "cclose")
	vim.notify("Tandem review: exited")
end

-- ── Surface focus / visibility ──────────────────────────────────
-- Cycle focus around a ring of [ your code window, each open Tandem input surface ].
-- So one key lets you leave an input (it stays open), pop to your buffer to make the
-- change, and come back — and reach any of several stacked bubbles.
function M.toggle_focus()
	local ring = {}
	for _, w in ipairs(vim.api.nvim_list_wins()) do -- one code (non-surface, non-float) window first
		if vim.api.nvim_win_get_config(w).relative == "" and not is_surface(w) then
			ring[#ring + 1] = w
			break
		end
	end
	for _, w in ipairs(vim.api.nvim_list_wins()) do -- then each Tandem input surface
		if is_surface(w) and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "prompt" then
			ring[#ring + 1] = w
		end
	end
	if #ring < 2 then
		vim.notify("Tandem: nothing to switch to")
		return
	end
	local cur = vim.api.nvim_get_current_win()
	local idx = 1
	for i, w in ipairs(ring) do
		if w == cur then
			idx = i
			break
		end
	end
	local nxt = ring[(idx % #ring) + 1]
	vim.cmd("stopinsert")
	vim.api.nvim_set_current_win(nxt)
	if vim.bo[vim.api.nvim_win_get_buf(nxt)].buftype == "prompt" then
		vim.cmd("startinsert")
	end
end

-- Close all open Tandem surfaces at once (clear the screen).
function M.close_surfaces()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if is_surface(w) and vim.api.nvim_win_is_valid(w) then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
	M._close_chat = nil
end

function M.hello()
	vim.notify("Tandem is loaded")
end

return M
