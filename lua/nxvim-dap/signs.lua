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
-- session_id -> { path, line }: every session's current stopped location. Multiple
-- concurrent sessions can each be stopped at once, so the stopped marker is keyed by
-- session and the whole set is repainted on any change (the stopped namespace is
-- cleared across all buffers, then each location re-marked).
local stopped_locs = {}

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

-- Mark session `sid`'s stopped line: a `▶` sign + a ranged highlight across the
-- line's text. 1-based `line`. Replaces that session's previous marker and repaints
-- every session's markers.
function M.set_stopped(sid, path, line)
  stopped_locs[sid] = { path = path, line = line }
  M.render_stopped()
end

-- Clear the stopped marker(s): for one session (`sid` given) or all (`sid` nil), then
-- repaint whatever remains.
function M.clear_stopped(sid)
  if sid == nil then
    stopped_locs = {}
  else
    stopped_locs[sid] = nil
  end
  M.render_stopped()
end

-- Repaint every session's stopped marker: sweep the stopped namespace off all buffers
-- (the only way to drop a removed session's mark without tracking extmark ids), then
-- re-mark each live location.
function M.render_stopped()
  for _, b in ipairs(nx.buf.list()) do
    nx.buf.clear_namespace(b, stopped_ns, 0, -1)
  end
  local s = cfg.stopped
  for _, loc in pairs(stopped_locs) do
    local bufnr = M.path_bufnr(loc.path)
    if bufnr then
      local text = nx.buf.lines(bufnr, loc.line - 1, loc.line, false)[1] or ""
      nx.buf.set_extmark(bufnr, stopped_ns, loc.line - 1, 0, {
        sign_text = s.text,
        sign_hl_group = s.hl,
        end_row = loc.line - 1,
        end_col = #text,
        hl_group = s.line_hl,
        priority = 30,
      })
    end
  end
end

return M
