-- The fallback highlight palette. Defined only when a group is undefined, so a
-- colorscheme that already styles the canonical `Dap*` / `NvimDap*`-style names (or
-- the user's `opts.highlights`) always wins regardless of load order — the same
-- fallback discipline nxvim-tree uses for `NvimTree*`.

local M = {}

-- group -> spec (nx.hl.define spec: fg/bg/bold/italic/…).
M.defaults = {
  NxDapBreakpoint = { fg = "#e51400" },
  NxDapBreakpointCondition = { fg = "#f9a825" },
  NxDapBreakpointRejected = { fg = "#9e9e9e" },
  NxDapLogPoint = { fg = "#2196f3" },
  NxDapStopped = { fg = "#ffd54f" },
  NxDapStoppedLine = { bg = "#3a3000" },
  -- Sidebar / REPL.
  NxDapUIScope = { fg = "#7aa2f7", bold = true },
  NxDapUIThread = { fg = "#9ece6a", bold = true },
  NxDapUIFrame = { fg = "#bb9af7" },
  NxDapUIFrameCurrent = { fg = "#ffd54f", bold = true },
  NxDapUIVarName = { fg = "#7dcfff" },
  NxDapUIVarType = { fg = "#565f89", italic = true },
  NxDapUIValue = { fg = "#c0caf5" },
  NxDapUIDecoration = { fg = "#565f89" },
  NxDapReplPrompt = { fg = "#9ece6a", bold = true },
  NxDapReplError = { fg = "#e51400" },
}

-- Apply the palette: an override always defines; a default only fills a group the
-- colorscheme left undefined.
function M.apply(overrides)
  overrides = overrides or {}
  for name, spec in pairs(M.defaults) do
    if overrides[name] then
      nx.hl.define(0, name, overrides[name])
    elseif not nx.hl.exists(name) then
      nx.hl.define(0, name, spec)
    end
  end
  for name, spec in pairs(overrides) do
    if not M.defaults[name] then
      nx.hl.define(0, name, spec)
    end
  end
end

return M
