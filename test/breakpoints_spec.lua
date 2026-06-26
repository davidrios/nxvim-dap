-- Breakpoint toggling in a live editor buffer: the store updates and the gutter
-- signs follow. Drives a real buffer (no debug session needed).

local dap = require("nxvim-dap")
local breakpoints = require("nxvim-dap.breakpoints")
local signs = require("nxvim-dap.signs")

local function bp_marks()
  local ns = nx.ns.create("nxvim-dap-breakpoints")
  return nx.buf.extmarks(nx.buf.current(), ns, 0, -1)
end

local function open_temp(t, body)
  local dir = nx.test.tempdir()
  local f = dir .. "/src.txt"
  nx.await(nx.fs.write(f, body or "one\ntwo\nthree\nfour\n"))
  t:cmd("edit " .. f)
  return f
end

nx.test.describe("nxvim-dap breakpoints", function()
  nx.test.before_each(function()
    dap.setup({})
    breakpoints.clear_all()
  end)

  nx.test.it("toggles a breakpoint at the cursor, with a gutter sign", function(t)
    local f = open_temp(t)
    t:feed("2G")
    dap.toggle_breakpoint()

    local bps = breakpoints.list()[signs.abspath(f)]
    nx.test.expect(bps).never.to_be_nil()
    nx.test.expect(#bps).to_be(1)
    nx.test.expect(bps[1].line).to_be(2)
    nx.test.expect(#bp_marks()).to_be(1)

    -- Toggling the same line again removes it (store + sign).
    dap.toggle_breakpoint()
    nx.test.expect(breakpoints.list()[signs.abspath(f)]).to_be_nil()
    nx.test.expect(#bp_marks()).to_be(0)
  end)

  nx.test.it("keeps breakpoints sorted by line across several toggles", function(t)
    local f = open_temp(t)
    t:feed("3G")
    dap.toggle_breakpoint()
    t:feed("1G")
    dap.toggle_breakpoint()
    t:feed("2G")
    dap.toggle_breakpoint()
    local bps = breakpoints.list()[signs.abspath(f)]
    nx.test.expect(#bps).to_be(3)
    nx.test.expect(bps[1].line .. bps[2].line .. bps[3].line).to_be("123")
    nx.test.expect(#bp_marks()).to_be(3)
  end)

  nx.test.it("upgrades a plain breakpoint to a conditional one", function(t)
    local f = open_temp(t)
    t:feed("2G")
    breakpoints.toggle()
    breakpoints.toggle({ condition = "x > 1" })
    local bps = breakpoints.list()[signs.abspath(f)]
    nx.test.expect(#bps).to_be(1) -- not removed, upgraded
    nx.test.expect(bps[1].condition).to_be("x > 1")
  end)

  nx.test.it("set_at_cursor edits a breakpoint in place (keeps it, never toggles off)", function(t)
    local f = open_temp(t)
    t:feed("2G")
    breakpoints.toggle() -- a plain breakpoint
    -- Edit it: add a condition + hit condition + log message.
    breakpoints.set_at_cursor({ condition = "i == 3", hitCondition = ">5", logMessage = "hi {i}" })
    local bps = breakpoints.list()[signs.abspath(f)]
    nx.test.expect(#bps).to_be(1) -- still one (edited, not removed)
    nx.test.expect(bps[1].condition).to_be("i == 3")
    nx.test.expect(bps[1].hitCondition).to_be(">5")
    nx.test.expect(bps[1].logMessage).to_be("hi {i}")

    -- get_at_cursor reads the breakpoint under the cursor back.
    local cur = breakpoints.get_at_cursor()
    nx.test.expect(cur.condition).to_be("i == 3")

    -- Clearing a field (nil) drops it without removing the breakpoint.
    breakpoints.set_at_cursor({ condition = "i == 3" })
    nx.test.expect(breakpoints.list()[signs.abspath(f)][1].hitCondition).to_be_nil()
    nx.test.expect(#breakpoints.list()[signs.abspath(f)]).to_be(1)
  end)

  nx.test.it("set_at_cursor creates a breakpoint when none exists at the cursor", function(t)
    local f = open_temp(t)
    t:feed("3G")
    breakpoints.set_at_cursor({ condition = "x" })
    local bps = breakpoints.list()[signs.abspath(f)]
    nx.test.expect(#bps).to_be(1)
    nx.test.expect(bps[1].line).to_be(3)
    nx.test.expect(bps[1].condition).to_be("x")
  end)

  nx.test.it("clear_all removes every breakpoint and sign", function(t)
    local f = open_temp(t)
    t:feed("1G")
    dap.toggle_breakpoint()
    t:feed("3G")
    dap.toggle_breakpoint()
    nx.test.expect(#bp_marks()).to_be(2)
    dap.clear_breakpoints()
    nx.test.expect(breakpoints.list()[signs.abspath(f)]).to_be_nil()
    nx.test.expect(#bp_marks()).to_be(0)
  end)

  nx.test.it("notifies and no-ops on a buffer with no file", function(t)
    t:cmd("enew")
    breakpoints.toggle()
    -- Nothing recorded for an unnamed buffer.
    local n = 0
    for _ in pairs(breakpoints.list()) do
      n = n + 1
    end
    nx.test.expect(n).to_be(0)
  end)
end)
