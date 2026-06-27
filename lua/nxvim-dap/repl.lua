-- The REPL / debug console: a bottom-dock `nx.view` that collects the adapter's
-- `output` events and the results of expressions you evaluate in the stopped frame.
-- A view is read-only, so input is entered through an `nx.ui.input` prompt (opened
-- with `<CR>`/`i` on the view, or `:DapEval`) rather than typed into the buffer —
-- the same pattern nxvim-tree uses for rename/create.

local M = {}

local view, ns, cfg
local session
local lines = {} -- the console scrollback
local marks = {} -- per-line highlight marks (parallel to lines)
local pending = "" -- partial output line awaiting its newline

local function ensure_view()
  if view then
    return
  end
  view = nx.view.create({ name = "nxvim-dap-repl", filetype = "nxdap-repl" })
  ns = nx.ns.create("nxvim-dap-repl")
  view:on_select(function()
    M.prompt()
  end)
end

function M.setup(config)
  cfg = config
end

function M.set_session(s)
  session = s
end

function M.is_open()
  return view ~= nil and view:winid() ~= nil
end

-- The REPL's backing buffer / window / 1-based cursor line (or nil before it exists).
-- For tests and the focus check.
function M.bufnr()
  return view and view:bufnr()
end
function M.winid()
  return view and view:winid()
end
function M.cursor_line()
  return view and view:line()
end

-- Whether the REPL is the focused window right now — the gate for auto-scrolling. Output
-- events shouldn't tail (and steal focus) while you're editing elsewhere.
local function is_focused()
  local win = view and view:winid()
  return win ~= nil and win == nx.win.current()
end

function M.open()
  ensure_view()
  if not M.is_open() then
    view:mount({ dock = cfg.repl.position, size = cfg.repl.height })
  end
  M.render()
end

function M.close()
  if view and M.is_open() then
    view:unmount()
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.render()
  if not view then
    return
  end
  view:set_lines(#lines > 0 and lines or { "" })
  view:set_decor(ns, marks)
  -- Tail the newest line, but ONLY while the REPL is the focused window — `set_cursor`
  -- focuses the view, so doing it on every render would let adapter output yank the
  -- cursor / steal focus while you're editing elsewhere. When the REPL is focused (you
  -- just evaluated, or you're reading it) it follows the output as before.
  if #lines > 0 and is_focused() then
    view:set_cursor(#lines)
  end
end

-- Append one display line, optionally highlighting the whole line with `hl`.
local function push(line, hl)
  lines[#lines + 1] = line
  if hl then
    marks[#marks + 1] =
      { line = #lines - 1, col = 0, end_row = #lines - 1, end_col = #line, hl_group = hl }
  end
end

-- Append text (which may contain several lines / a partial tail) from an output
-- stream, keeping an unterminated fragment buffered until its newline arrives.
function M.append_output(_category, text)
  pending = pending .. text:gsub("\r\n", "\n")
  local flushed = false
  while true do
    local nl = pending:find("\n", 1, true)
    if not nl then
      break
    end
    push(pending:sub(1, nl - 1))
    pending = pending:sub(nl + 1)
    flushed = true
  end
  if flushed then
    M.render()
  end
end

-- Flush any buffered partial line (on session end), so a trailing prompt without a
-- newline isn't lost.
function M.flush()
  if pending ~= "" then
    push(pending)
    pending = ""
    M.render()
  end
end

-- Echo a one-off informational line (session lifecycle).
function M.info(text)
  push(text, "NxDapUIDecoration")
  M.render()
end

-- Evaluate `expr` in the current stopped frame and append the prompt + result.
function M.eval(expr)
  if expr == nil or expr == "" then
    return
  end
  push("> " .. expr, "NxDapReplPrompt")
  M.render()
  if not session then
    push("  (no active session)", "NxDapReplError")
    M.render()
    return
  end
  local frame_id = session.current_frame and session.current_frame.id
  session:evaluate(expr, frame_id, "repl", function(err, body)
    if err then
      push("  " .. tostring(err.message), "NxDapReplError")
    else
      for _, l in ipairs(vim.split((body and body.result) or "", "\n")) do
        push("  " .. l)
      end
    end
    M.render()
  end)
end

-- Open an input prompt for the next REPL expression. `history` gives the prompt
-- readline-style recall (`<Up>`/`<Down>`) over the expressions evaluated this
-- session, scoped to its own namespace so it's independent of the `:` / search
-- histories and of any other plugin's input history.
function M.prompt()
  nx.ui.input({ prompt = "dap> ", history = "nxvim-dap-repl" }):next(function(expr)
    if expr then
      M.eval(expr)
    end
  end)
end

function M.clear()
  lines = {}
  marks = {}
  pending = ""
  if view then
    M.render()
  end
end

-- Tear the REPL fully down — drop its view (and dock) and scrollback — so it starts from
-- a clean slate. For tests that need a hermetic REPL independent of any prior session.
function M._reset()
  if view then
    view:close()
    view = nil
  end
  lines = {}
  marks = {}
  pending = ""
end

return M
