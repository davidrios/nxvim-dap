-- The debug sidebar: a read-only `nx.view` mounted in an edge dock showing the
-- stopped thread's stack frames and the selected frame's scopes / variables. The
-- view OWNS its lines (no buffer mutation); each rendered row carries opaque
-- userdata so `<CR>` knows whether it hit a frame (jump + reselect) or an expandable
-- variable (lazy-load its children and toggle).

local M = {}

local view, ns, cfg
local session -- the active session to query
local state = {
  frames = {}, -- the stopped thread's stack
  scopes = {}, -- the current frame's scopes, each with a resolved `variables`
  expanded = {}, -- variablesReference -> true
  children = {}, -- variablesReference -> resolved child list (lazy)
}

-- on_jump(path, line): focus the editor on a frame's source. Set by init.lua.
M.on_jump = nil

local function ensure_view()
  if view then
    return
  end
  view = nx.view.create({ name = "nxvim-dap-ui", filetype = "nxdap-ui" })
  ns = nx.ns.create("nxvim-dap-ui")
  view:on_select(function(_line, data)
    M._on_select(data)
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

function M.open()
  ensure_view()
  if not M.is_open() then
    view:mount({ dock = cfg.sidebar.position, size = cfg.sidebar.width })
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

-- Reset to the empty (no-session) state.
function M.clear()
  state = { frames = {}, scopes = {}, expanded = {}, children = {} }
  if view then
    M.render()
  end
end

-- A new stopped snapshot arrived: store the frames, focus the top frame, and load
-- its scopes, then render.
function M.show_stopped(snapshot)
  state.frames = snapshot.frames or {}
  state.scopes = {}
  state.expanded = {}
  state.children = {}
  local top = state.frames[1]
  if cfg.sidebar.open_on_stopped then
    M.open()
  end
  if top and session then
    M.focus_frame(top)
  else
    M.render()
  end
end

-- Make `frame` the active frame: load its scopes (one level of variables) and render.
function M.focus_frame(frame)
  state.current = frame
  if not session then
    M.render()
    return
  end
  session:frame_scopes(frame.id, function(scopes)
    state.scopes = scopes
    state.expanded = {}
    state.children = {}
    M.render()
  end)
end

-- ----- selection handling ----------------------------------------------------

function M._on_select(data)
  if not data then
    return
  end
  if data.kind == "frame" then
    state.current = data.frame
    if M.on_jump and data.frame.source and data.frame.source.path then
      M.on_jump(data.frame.source.path, data.frame.line)
    end
    M.focus_frame(data.frame)
  elseif data.kind == "var" then
    local ref = data.var.variablesReference or 0
    if ref == 0 then
      return
    end
    if state.expanded[ref] then
      state.expanded[ref] = nil
      M.render()
    elseif state.children[ref] then
      state.expanded[ref] = true
      M.render()
    elseif session then
      session:variables(ref, function(vars)
        state.children[ref] = vars
        state.expanded[ref] = true
        M.render()
      end)
    end
  end
end

-- ----- rendering -------------------------------------------------------------

-- Append a variable row (recursing into expanded children) to lines/userdata/marks.
local function render_var(var, depth, lines, data, marks)
  local ref = var.variablesReference or 0
  local marker = ref > 0 and (state.expanded[ref] and "▾ " or "▸ ") or "  "
  local indent = string.rep("  ", depth)
  local name_col = #indent + #marker
  local prefix = indent .. marker .. var.name
  local line = prefix .. " = " .. (var.value or "")
  lines[#lines + 1] = line
  data[#data + 1] = { kind = "var", var = var }
  local row = #lines - 1
  marks[#marks + 1] = {
    line = row,
    col = name_col,
    end_row = row,
    end_col = name_col + #var.name,
    hl_group = "NxDapUIVarName",
  }
  local val_col = #prefix + 3
  marks[#marks + 1] =
    { line = row, col = val_col, end_row = row, end_col = #line, hl_group = "NxDapUIValue" }
  if state.expanded[ref] and state.children[ref] then
    for _, child in ipairs(state.children[ref]) do
      render_var(child, depth + 1, lines, data, marks)
    end
  end
end

function M.render()
  if not view then
    return
  end
  local lines, data, marks = {}, {}, {}
  local function header(text, hl)
    lines[#lines + 1] = text
    data[#data + 1] = { kind = "header" }
    marks[#marks + 1] =
      { line = #lines - 1, col = 0, end_row = #lines - 1, end_col = #text, hl_group = hl }
  end

  if #state.frames == 0 then
    lines = { "  no active stop" }
    data = { { kind = "header" } }
    view:set_userdata(data)
    view:set_lines(lines)
    view:set_decor(ns, {})
    return
  end

  header("STACK FRAMES", "NxDapUIThread")
  for _, frame in ipairs(state.frames) do
    local cur = state.current and state.current.id == frame.id
    local loc = ""
    if frame.source and frame.source.path then
      loc = "  "
        .. (frame.source.path:match("[^/]+$") or frame.source.path)
        .. ":"
        .. tostring(frame.line)
    end
    local sigil = cur and "→ " or "  "
    lines[#lines + 1] = " " .. sigil .. frame.name .. loc
    data[#data + 1] = { kind = "frame", frame = frame }
    marks[#marks + 1] = {
      line = #lines - 1,
      col = 0,
      end_row = #lines - 1,
      end_col = #lines[#lines],
      hl_group = cur and "NxDapUIFrameCurrent" or "NxDapUIFrame",
    }
  end

  lines[#lines + 1] = ""
  data[#data + 1] = { kind = "header" }
  header("SCOPES", "NxDapUIThread")
  for _, scope in ipairs(state.scopes) do
    header("  " .. scope.name, "NxDapUIScope")
    for _, var in ipairs(scope.variables or {}) do
      render_var(var, 1, lines, data, marks)
    end
  end

  view:set_userdata(data)
  view:set_lines(lines)
  view:set_decor(ns, marks)
end

return M
