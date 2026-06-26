-- Gutter signs + the stopped-line highlight, painted into REAL editor buffers via
-- extmarks (not a view). Two namespaces keep the concerns independent: breakpoint
-- signs persist across stops, while the single stopped marker moves with execution.
--
-- Only `sign_text` and a ranged `hl_group` actually render through nxvim's extmark
-- layer (a whole-line `line_hl_group` is stored-but-unpainted), so the stopped line
-- is drawn as a sign PLUS a ranged highlight spanning the line's text.

local M = {}

local bp_ns, stopped_ns
local cfg
local stopped_loc -- { bufnr, line } currently marked, for clearing

function M.setup(config)
  cfg = config
  bp_ns = bp_ns or nx.ns.create("nxvim-dap-breakpoints")
  stopped_ns = stopped_ns or nx.ns.create("nxvim-dap-stopped")
end

-- Absolute, symlink-naive normalization so a breakpoint path and a buffer name
-- compare equal regardless of how either was spelled.
local function abspath(p)
  if not p or p == "" then
    return p
  end
  if vim and vim.fn and vim.fn.fnamemodify then
    return vim.fn.fnamemodify(p, ":p")
  end
  return p
end
M.abspath = abspath

-- The loaded buffer for `path`, or nil if the file isn't open (then it carries no
-- signs — they appear when it's next opened and breakpoints re-sync).
function M.path_bufnr(path)
  local want = abspath(path)
  for _, b in ipairs(nx.buf.list()) do
    local name = nx.buf.name(b)
    if name and name ~= "" and abspath(name) == want then
      return b
    end
  end
end

local function variant(bp)
  if bp.logMessage then
    return cfg.log_point
  elseif bp.condition or bp.hitCondition then
    return cfg.breakpoint_condition
  elseif bp.rejected then
    return cfg.breakpoint_rejected
  end
  return cfg.breakpoint
end

-- Repaint every breakpoint sign for `path` (clears the file's breakpoint namespace
-- first). `bps` is the list of `{ line, condition?, logMessage?, rejected? }`.
function M.render_breakpoints(path, bps)
  local bufnr = M.path_bufnr(path)
  if not bufnr then
    return
  end
  nx.buf.clear_namespace(bufnr, bp_ns, 0, -1)
  for _, bp in ipairs(bps) do
    local v = variant(bp)
    nx.buf.set_extmark(bufnr, bp_ns, bp.line - 1, 0, {
      sign_text = v.text,
      sign_hl_group = v.hl,
      priority = 20,
    })
  end
end

-- Clear breakpoint signs on a single file (used when its last breakpoint is removed).
function M.clear_breakpoints(path)
  local bufnr = M.path_bufnr(path)
  if bufnr then
    nx.buf.clear_namespace(bufnr, bp_ns, 0, -1)
  end
end

-- Mark the stopped line: a `▶` sign + a ranged highlight across the line's text.
-- 1-based `line`. Clears any previous stopped marker first.
function M.set_stopped(path, line)
  M.clear_stopped()
  local bufnr = M.path_bufnr(path)
  if not bufnr then
    return
  end
  local s = cfg.stopped
  local text = nx.buf.lines(bufnr, line - 1, line, false)[1] or ""
  nx.buf.set_extmark(bufnr, stopped_ns, line - 1, 0, {
    sign_text = s.text,
    sign_hl_group = s.hl,
    end_row = line - 1,
    end_col = #text,
    hl_group = s.line_hl,
    priority = 30,
  })
  stopped_loc = { bufnr = bufnr, line = line }
end

function M.clear_stopped()
  if stopped_loc then
    nx.buf.clear_namespace(stopped_loc.bufnr, stopped_ns, 0, -1)
    stopped_loc = nil
  end
  -- Also sweep any other buffer that might carry a stale marker (e.g. the file was
  -- reopened in a different buffer).
  for _, b in ipairs(nx.buf.list()) do
    nx.buf.clear_namespace(b, stopped_ns, 0, -1)
  end
end

return M
