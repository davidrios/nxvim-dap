-- End-to-end: the whole client against a REAL debug adapter subprocess (a scripted
-- DAP server, test/support/mock_adapter.py) spoken over `nx.process` — the same
-- duplex-stdio path a real adapter uses. This proves the integration the fake-
-- transport session_spec can't: framing over a live pipe, the launch handshake,
-- breakpoint sync, the stopped drill-down, stepping, evaluate, and teardown.
--
-- Needs `python3` on PATH (the mock's interpreter). If your environment lacks it,
-- this is the only spec that won't run; the protocol logic is covered hermetically
-- by rpc_spec / session_spec.

local dap = require("nxvim-dap")

-- The plugin root: the runner puts `<root>/lua/?.lua` first on package.path (the
-- runtimepath drives module search), so the mock adapter resolves beneath it.
-- (debug.getinfo / vim.o.runtimepath are unreliable here — specs are sourced as
-- strings, and the test runtime leaves vim.o.runtimepath nil.)
local ROOT = package.path:match("(.-)/lua/%?%.lua") or "."
local MOCK = ROOT .. "/test/support/mock_adapter.py"

local function setup_session(t, prog)
  dap.setup({ jump_to_stopped = true })
  dap.adapters.mock = { command = "python3", args = { MOCK } }
  dap.configurations.nxdapmock = {
    { type = "mock", request = "launch", name = "mock launch", program = prog },
  }
  dap.run({ type = "mock", request = "launch", name = "mock launch", program = prog })
end

local function wait_stopped(t, line)
  t:wait_for(function()
    local s = dap.session()
    return s
      and s.stopped_thread_id ~= nil
      and s.current_frame ~= nil
      and s.current_frame.line == line
  end, { tries = 300, interval = 20, message = "session did not stop at line " .. tostring(line) })
end

nx.test.describe("nxvim-dap end-to-end (real adapter over nx.process)", function()
  -- The --test-plugin runner doesn't source `plugin/`, so set the plugin up first
  -- (signs/ui/repl need their config) before any breakpoint toggle.
  nx.test.before_each(function()
    dap.setup({ jump_to_stopped = true })
  end)

  nx.test.it("launches, hits a breakpoint, steps, evaluates, and terminates", function(t)
    local dir = nx.test.tempdir()
    local prog = dir .. "/prog.py"
    nx.await(nx.fs.write(prog, "a = 1\nb = 2\nc = 3\n"))
    t:cmd("edit " .. prog)

    -- Toggle a breakpoint on line 2.
    t:feed("2G")
    dap.toggle_breakpoint()
    nx.test.expect(dap.breakpoints.list()[dap.signs.abspath(prog)]).never.to_be_nil()
    nx.test.expect(dap.breakpoints.list()[dap.signs.abspath(prog)][1].line).to_be(2)

    -- Launch the adapter; it stops at line 2.
    setup_session(t, prog)
    wait_stopped(t, 2)

    local s = dap.session()
    nx.test.expect(s.current_frame.name).to_be("main")
    nx.test.expect(s.capabilities.supportsConfigurationDoneRequest).to_be_truthy()

    -- The stopped marker landed in the source buffer (a sign in its namespace).
    local stopped_ns = nx.ns.create("nxvim-dap-stopped")
    local marks = nx.buf.extmarks(dap.signs.path_bufnr(prog), stopped_ns, 0, -1)
    nx.test.expect(#marks).never.to_be(0)

    -- Evaluate an expression in the stopped frame over the live adapter.
    local evaluated
    s:evaluate("1+1", s.current_frame.id, "repl", function(err, body)
      evaluated = err and ("ERR:" .. tostring(err.message)) or body.result
    end)
    t:wait_for(function()
      return evaluated
    end, { tries = 200, interval = 20, message = "evaluate did not return" })
    nx.test.expect(evaluated).to_be("1+1 => ok")

    -- Step over → the adapter stops again at line 3.
    dap.step_over()
    wait_stopped(t, 3)
    nx.test.expect(dap.session().current_frame.line).to_be(3)

    -- Continue → the adapter terminates; the plugin tears the session down.
    dap.continue()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })

    -- The stopped marker is cleared on teardown.
    local cleared = nx.buf.extmarks(dap.signs.path_bufnr(prog), stopped_ns, 0, -1)
    nx.test.expect(#cleared).to_be(0)
  end)

  nx.test.it("resolves scopes and variables from the live adapter", function(t)
    local dir = nx.test.tempdir()
    local prog = dir .. "/prog2.py"
    nx.await(nx.fs.write(prog, "x = 1\ny = 2\n"))
    t:cmd("edit " .. prog)

    setup_session(t, prog)
    wait_stopped(t, 2)

    local scopes
    dap.session():frame_scopes(dap.session().current_frame.id, function(s)
      scopes = s
    end)
    t:wait_for(function()
      return scopes
    end, { tries = 200, interval = 20, message = "scopes did not resolve" })
    nx.test.expect(#scopes).to_be(1)
    nx.test.expect(scopes[1].name).to_be("Locals")
    nx.test.expect(scopes[1].variables[1].name).to_be("x")
    nx.test.expect(scopes[1].variables[1].value).to_be("42")

    dap.terminate()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "session did not terminate" })
  end)

  nx.test.it("connects to a server (TCP) adapter and runs the same flow", function(t)
    local dir = nx.test.tempdir()
    local prog = dir .. "/prog3.py"
    nx.await(nx.fs.write(prog, "x = 1\ny = 2\n"))
    local port_file = dir .. "/port"

    -- Launch the mock in server mode: it binds an ephemeral TCP port and writes it to
    -- port_file. (The test owns the process; the adapter config has no `executable`,
    -- so the plugin just connects.)
    local server = nx.process.open({
      cmd = "python3",
      args = { MOCK, "--listen", "--port-file", port_file },
    })

    -- Poll for the announced port (the file appears once the server is bound).
    local port
    for _ = 1, 200 do
      local ok, data = pcall(function()
        return nx.await(nx.fs.read_text(port_file))
      end)
      if ok and data and tonumber(data) then
        port = tonumber(data)
        break
      end
      nx.await(nx.promise.delay(20))
    end
    nx.test.expect(port).never.to_be_nil()

    t:cmd("edit " .. prog)
    dap.adapters.srv = { type = "server", host = "127.0.0.1", port = port }
    dap.run({ type = "srv", request = "launch", name = "srv launch", program = prog })

    wait_stopped(t, 2)
    nx.test.expect(dap.session().current_frame.name).to_be("main")
    nx.test.expect(dap.session().capabilities.supportsConfigurationDoneRequest).to_be_truthy()

    -- Step + continue work the same over the socket.
    dap.step_over()
    wait_stopped(t, 3)

    dap.continue()
    t:wait_for(function()
      return dap.session() == nil
    end, { tries = 300, interval = 20, message = "server session did not terminate" })

    server:kill()
  end)
end)
