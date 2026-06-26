-- nxvim-dap — a Debug Adapter Protocol client for nxvim, built entirely on the
-- native `nx.*` plugin API (ADR 0002). It is the nxvim sibling of nvim-dap: the same
-- two-table model (`adapters` = how to reach a debug adapter, `configurations` = what
-- to debug per filetype), the same launch/attach flow, breakpoints, stepping, a
-- scopes/variables sidebar and a REPL — re-expressed in nxvim's idiom.
--
-- The keystone is `nx.process` (the duplex child transport): a debug adapter speaks
-- Content-Length-framed JSON over stdio exactly like a language server, which neither
-- `nx.run` nor `nx.run_stream` can carry (they close stdin and line-split stdout).
--
-- Module map:
--   config.lua       defaults + adapter/configuration validation
--   rpc.lua          the Content-Length wire codec
--   session.lua      the DAP protocol state machine over an injected transport
--   breakpoints.lua  the breakpoint store + cursor toggle
--   signs.lua        gutter signs + the stopped-line highlight (real buffers)
--   ui.lua           the stack/scopes/variables sidebar (an nx.view dock)
--   repl.lua         the debug console (output + evaluate)
--   highlights.lua   the fallback highlight palette
--
-- Quick start (init.lua):
--   local dap = require("nxvim-dap")
--   dap.setup({})
--   dap.adapters.python = { command = "python", args = { "-m", "debugpy.adapter" } }
--   dap.configurations.python = {
--     { type = "python", request = "launch", name = "file", program = "${file}" },
--   }
--   -- then <F5> / :DapContinue starts it, <leader>db toggles a breakpoint.

local config_mod = require("nxvim-dap.config")
local session_mod = require("nxvim-dap.session")
local breakpoints = require("nxvim-dap.breakpoints")
local signs = require("nxvim-dap.signs")
local ui = require("nxvim-dap.ui")
local repl = require("nxvim-dap.repl")
local highlights = require("nxvim-dap.highlights")

local M = {}

M.config = config_mod.defaults()
-- The public registries (nvim-dap parity): users assign into these directly.
M.adapters = {}
M.configurations = {}

M._session = nil
local hl_applied = false
local autocmds_wired = false

-- ----- session lifecycle -----------------------------------------------------

-- Open the file at `path` in the MAIN editor and put the cursor on `line` (1-based).
-- The cursor set defers a tick so the buffer/window have settled after the open.
local function jump(path, line)
  nx.open(path, { where = "main" })
  nx.on_next_tick(function()
    nx.cursor.set({ line, 0 })
  end)
end

function M._on_terminated(body)
  signs.clear_stopped()
  ui.clear()
  ui.set_session(nil)
  repl.flush()
  repl.set_session(nil)
  local exit = body and body.exitCode
  repl.info(
    "─ session terminated"
      .. (exit ~= nil and (" (exit " .. tostring(exit) .. ")") or "")
      .. " ─"
  )
  M._session = nil
end

-- Start a concrete launch/attach `config` (resolving its adapter by `config.type`).
function M.run(config)
  config = config_mod.validate_configuration(config)
  local adapter = M.adapters[config.type]
  if not adapter then
    nx.notify(("nxvim-dap: no adapter registered for type %q"):format(config.type), 4)
    return
  end

  -- One session at a time: end any prior one first.
  if M._session and not M._session.terminated then
    M._session:disconnect()
  end
  ui.clear()
  repl.clear()
  if M.config.repl.open_on_start then
    repl.open()
  end
  repl.info("─ starting " .. config.name .. " ─")

  local handlers = {
    get_breakpoints = breakpoints.list,
    notify = function(msg, lvl)
      nx.notify(msg, lvl)
    end,
    on_output = function(category, text)
      repl.append_output(category, text)
    end,
    on_stopped = function(_body, snapshot)
      local frame = snapshot.frames and snapshot.frames[1]
      if frame and frame.source and frame.source.path then
        signs.set_stopped(frame.source.path, frame.line)
        if M.config.jump_to_stopped then
          jump(frame.source.path, frame.line)
        end
      end
      ui.show_stopped(snapshot)
    end,
    on_continued = function()
      signs.clear_stopped()
    end,
    on_terminated = function(body)
      M._on_terminated(body)
    end,
    on_state = function(_st) end,
  }

  local session = session_mod.spawn(adapter, config, handlers)
  M._session = session
  ui.set_session(session)
  repl.set_session(session)
end

-- Start debugging, or resume if a session is already stopped. With no running
-- session, pick a configuration for the current buffer's filetype.
function M.continue()
  if M._session and not M._session.terminated then
    M._session:continue()
    return
  end
  local ft = vim.bo[nx.buf.current()].filetype
  local cfgs = M.configurations[ft]
  if not cfgs or #cfgs == 0 then
    nx.notify(("nxvim-dap: no debug configuration for filetype %q"):format(tostring(ft)), 3)
    return
  end
  if #cfgs == 1 then
    M.run(cfgs[1])
  else
    nx.ui
      .select(cfgs, {
        prompt = "Debug configuration",
        format_item = function(c)
          return c.name
        end,
      })
      :next(function(choice)
        -- nx.ui.select resolves the chosen item (or its index — tolerate both).
        local cfg = type(choice) == "number" and cfgs[choice] or choice
        if cfg then
          M.run(cfg)
        end
      end)
  end
end

local function require_session()
  if not M._session or M._session.terminated then
    nx.notify("nxvim-dap: no active session", 3)
    return nil
  end
  return M._session
end

function M.step_over()
  local s = require_session()
  if s then
    s:step_over()
  end
end
function M.step_into()
  local s = require_session()
  if s then
    s:step_into()
  end
end
function M.step_out()
  local s = require_session()
  if s then
    s:step_out()
  end
end
function M.pause()
  local s = require_session()
  if s then
    s:pause()
  end
end

function M.terminate()
  if M._session and not M._session.terminated then
    M._session:disconnect({ terminate = true })
  else
    M._on_terminated(nil)
  end
end

function M.session()
  return M._session
end

-- ----- breakpoints -----------------------------------------------------------

function M.toggle_breakpoint()
  breakpoints.toggle()
end

function M.set_breakpoint_condition()
  nx.ui.input({ prompt = "Breakpoint condition: " }):next(function(cond)
    if cond and cond ~= "" then
      breakpoints.toggle({ condition = cond })
    end
  end)
end

function M.set_log_point()
  nx.ui.input({ prompt = "Log point message: " }):next(function(msg)
    if msg and msg ~= "" then
      breakpoints.toggle({ logMessage = msg })
    end
  end)
end

function M.clear_breakpoints()
  breakpoints.clear_all()
end

-- ----- UI surfaces -----------------------------------------------------------

function M.repl_toggle()
  repl.toggle()
end
function M.sidebar_toggle()
  ui.toggle()
end
function M.eval(expr)
  repl.open()
  if expr and expr ~= "" then
    repl.eval(expr)
  else
    repl.prompt()
  end
end

-- ----- setup -----------------------------------------------------------------

local COMMANDS = {
  { "DapContinue", "continue", "Start or resume debugging" },
  { "DapStepOver", "step_over", "Step over" },
  { "DapStepInto", "step_into", "Step into" },
  { "DapStepOut", "step_out", "Step out" },
  { "DapPause", "pause", "Pause execution" },
  { "DapTerminate", "terminate", "Terminate the debug session" },
  { "DapToggleBreakpoint", "toggle_breakpoint", "Toggle a breakpoint at the cursor" },
  { "DapBreakpointCondition", "set_breakpoint_condition", "Set a conditional breakpoint" },
  { "DapLogPoint", "set_log_point", "Set a log point" },
  { "DapClearBreakpoints", "clear_breakpoints", "Remove every breakpoint" },
  { "DapReplToggle", "repl_toggle", "Toggle the debug REPL" },
  { "DapSidebarToggle", "sidebar_toggle", "Toggle the scopes/stack sidebar" },
}

local MAP_ACTIONS = {
  continue = M.continue,
  step_over = M.step_over,
  step_into = M.step_into,
  step_out = M.step_out,
  toggle_breakpoint = M.toggle_breakpoint,
  toggle_breakpoint_condition = M.set_breakpoint_condition,
  repl_toggle = M.repl_toggle,
  sidebar_toggle = M.sidebar_toggle,
  terminate = M.terminate,
}

-- setup() is re-runnable: a full reconfigure merged fresh from the defaults.
function M.setup(opts)
  M.config = config_mod.merge(config_mod.defaults(), opts or {})

  -- Seed registries from opts (and keep the live tables for direct assignment).
  for k, v in pairs(M.config.adapters or {}) do
    M.adapters[k] = v
  end
  for k, v in pairs(M.config.configurations or {}) do
    M.configurations[k] = v
  end

  if not hl_applied then
    highlights.apply(M.config.highlights)
    hl_applied = true
  end

  signs.setup(M.config.signs)
  ui.setup(M.config)
  repl.setup(M.config)

  -- Push breakpoint changes to a live, configured session.
  breakpoints.on_change = function(path, bps)
    if M._session and M._session.initialized and not M._session.terminated then
      M._session:set_breakpoints(path, bps)
    end
  end

  -- Wire the jump-to-source the sidebar uses for frame selection.
  ui.on_jump = jump

  for _, c in ipairs(COMMANDS) do
    local name, fn_name, desc = c[1], c[2], c[3]
    nx.command(name, function()
      M[fn_name]()
    end, { desc = desc })
  end
  nx.command("DapEval", function(ev)
    M.eval(ev and ev.args)
  end, { desc = "Evaluate an expression in the stopped frame" })

  -- Default keymaps (any false entry, or `mappings = false`, disables it).
  if M.config.mappings ~= false then
    for action, lhs in pairs(M.config.mappings) do
      if lhs and MAP_ACTIONS[action] then
        nx.keymap.set("n", lhs, MAP_ACTIONS[action], { desc = "nxvim-dap: " .. action })
      end
    end
  end

  -- Repaint breakpoint signs when a buffer opens (so signs set while it was closed
  -- appear), and on the next tick after setup for already-open buffers.
  if not autocmds_wired then
    local grp = nx.augroup.create("nxvim-dap", { clear = true })
    nx.autocmd.create("BufEnter", {
      group = grp,
      callback = function()
        breakpoints.render_all()
      end,
    })
    autocmds_wired = true
  end
  nx.on_next_tick(function()
    breakpoints.render_all()
  end)

  return M
end

-- Expose internals for tests / advanced users.
M.breakpoints = breakpoints
M.signs = signs
M.ui = ui
M.repl = repl

return M
