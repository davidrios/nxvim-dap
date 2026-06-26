-- A single debug session: the DAP protocol state machine over a duplex transport.
--
-- The transport is INJECTED (`{ write = fn(str), close = fn() }`) rather than baked
-- in, so the protocol logic — the initialize/launch handshake, request/response
-- correlation by `seq`, event dispatch, the stopped→threads→stackTrace→scopes→
-- variables drill-down — is testable against a fake transport with no subprocess,
-- and `M.spawn` is the thin adapter that wires a real `nx.process` child to it.
--
-- The session is UI-agnostic: it owns protocol state and fires `handlers.*`
-- listeners (on_stopped / on_continued / on_terminated / on_output / on_event /
-- on_state). init.lua registers those to drive the signs / sidebar / REPL.

local rpc = require("nxvim-dap.rpc")

local M = {}

local Session = {}
Session.__index = Session
M.Session = Session

-- Create a session over `transport` (`{ write, close }`). `handlers` is a table of
-- optional listener callbacks (see file header) plus `notify(msg, level)`.
function M.new(transport, handlers)
  return setmetatable({
    transport = transport,
    handlers = handlers or {},
    seq = 0,
    pending = {}, -- request seq -> cb(err, body)
    decode = nil, -- the rpc decoder feed fn (set below)
    capabilities = {},
    config = nil, -- the launch/attach configuration in flight
    initialized = false, -- the `initialized` event arrived + we configured
    stopped_thread_id = nil,
    current_frame = nil, -- the frame the UI is focused on
    threads = {}, -- id -> { id, name, stopped }
    terminated = false,
  }, Session)
end

local function notify(self, msg, level)
  if self.handlers.notify then
    self.handlers.notify(msg, level or 3)
  else
    nx.notify(msg, level or 3)
  end
end
M._notify = notify

-- ----- wire I/O --------------------------------------------------------------

-- Feed a raw transport chunk through the decoder (lazily built so a single decoder
-- buffers the partial tail across chunks).
function Session:feed(chunk)
  if not self.decode then
    self.decode = rpc.decoder(function(msg)
      self:_on_message(msg)
    end, function(err)
      notify(self, err, 4)
    end)
  end
  self.decode(chunk)
end

-- Send a request and register `cb(err, body)` for its response. `err` is nil on
-- success, else `{ message = ... }`.
function Session:request(command, arguments, cb)
  self.seq = self.seq + 1
  local seq = self.seq
  if cb then
    self.pending[seq] = cb
  end
  self.transport.write(rpc.encode({
    seq = seq,
    type = "request",
    command = command,
    arguments = arguments,
  }))
  return seq
end

-- Respond to a reverse request the adapter sent us (runInTerminal / startDebugging).
function Session:respond(request_msg, success, body, message)
  self.seq = self.seq + 1
  self.transport.write(rpc.encode({
    seq = self.seq,
    type = "response",
    request_seq = request_msg.seq,
    success = success,
    command = request_msg.command,
    body = body,
    message = message,
  }))
end

-- ----- inbound dispatch ------------------------------------------------------

function Session:_on_message(msg)
  if msg.type == "response" then
    local cb = self.pending[msg.request_seq]
    self.pending[msg.request_seq] = nil
    if cb then
      if msg.success then
        cb(nil, msg.body)
      else
        cb({ message = msg.message or (msg.body and msg.body.error) or "request failed" }, msg.body)
      end
    end
  elseif msg.type == "event" then
    self:_on_event(msg.event, msg.body or {})
  elseif msg.type == "request" then
    self:_on_reverse_request(msg)
  end
  if self.handlers.on_event then
    self.handlers.on_event(msg)
  end
end

-- Reverse requests: the adapter asking US to do something. We support the ones a
-- stdio session can honor and REJECT the rest loud (so the adapter sees a real
-- failure response, never silence).
function Session:_on_reverse_request(msg)
  if msg.command == "runInTerminal" then
    -- Launch the debuggee as a detached duplex child. We can't give it a real TTY
    -- (nxvim has no Lua terminal-buffer spawn API yet), so a program needing an
    -- interactive console won't get one — but the common case (a program that just
    -- runs) works. Report the failure loud if the spawn never starts.
    local body = msg.arguments or {}
    local argv = body.args or {}
    if #argv == 0 then
      self:respond(msg, false, nil, "runInTerminal: empty args")
      return
    end
    local cmd = table.remove(argv, 1)
    local ok = pcall(function()
      nx.process.open({
        cmd = cmd,
        args = argv,
        cwd = body.cwd,
        env = body.env,
        on_stdout = function(chunk)
          if self.handlers.on_output then
            self.handlers.on_output("stdout", chunk)
          end
        end,
        on_stderr = function(chunk)
          if self.handlers.on_output then
            self.handlers.on_output("stderr", chunk)
          end
        end,
      })
    end)
    self:respond(msg, ok, ok and {} or nil, ok and nil or "runInTerminal: spawn failed")
  else
    self:respond(msg, false, nil, ("nxvim-dap: unsupported reverse request %q"):format(msg.command))
  end
end

function Session:_on_event(event, body)
  if event == "initialized" then
    self:_configure()
  elseif event == "stopped" then
    self:_on_stopped(body)
  elseif event == "continued" then
    if body.allThreadsContinued ~= false then
      self.stopped_thread_id = nil
      self.current_frame = nil
    end
    if self.handlers.on_continued then
      self.handlers.on_continued(body)
    end
  elseif event == "thread" then
    self.dirty_threads = true
  elseif event == "output" then
    if self.handlers.on_output then
      self.handlers.on_output(body.category or "console", body.output or "")
    end
  elseif event == "terminated" or event == "exited" then
    if not self.terminated then
      self.terminated = true
      if self.handlers.on_terminated then
        self.handlers.on_terminated(body)
      end
    end
  elseif event == "capabilities" then
    if body.capabilities then
      for k, v in pairs(body.capabilities) do
        self.capabilities[k] = v
      end
    end
  end
end

-- ----- the launch/attach handshake -------------------------------------------

-- Begin the session for `config` (a validated launch/attach configuration): send
-- `initialize`, store capabilities, then fire the launch/attach request. The
-- adapter's `initialized` event drives `_configure` (breakpoints + configurationDone).
function Session:start(config)
  self.config = config
  self:request("initialize", {
    clientID = "nxvim",
    clientName = "nxvim",
    adapterID = config.type,
    locale = "en",
    linesStartAt1 = true,
    columnsStartAt1 = true,
    pathFormat = "path",
    supportsRunInTerminalRequest = true,
    supportsVariableType = true,
  }, function(err, body)
    if err then
      notify(self, "nxvim-dap: initialize failed: " .. tostring(err.message), 4)
      self:disconnect()
      return
    end
    self.capabilities = body or {}
    if self.handlers.on_state then
      self.handlers.on_state("initialized")
    end
    -- Fire launch/attach; its response arrives after configurationDone.
    self:request(config.request, config, function(lerr)
      if lerr then
        notify(self, ("nxvim-dap: %s failed: %s"):format(config.request, tostring(lerr.message)), 4)
      end
    end)
  end)
end

-- The adapter is ready for configuration (`initialized` event): push breakpoints for
-- every source, set exception breakpoints, then configurationDone. `get_breakpoints`
-- is supplied by init.lua (it owns the breakpoint store): `() -> { [path] = { {line,
-- condition, logMessage}, ... } }`.
function Session:_configure()
  local sources = self.handlers.get_breakpoints and self.handlers.get_breakpoints() or {}
  local pending = 1 -- a virtual "all sources queued" token, released at the end
  local function done()
    pending = pending - 1
    if pending == 0 then
      self:_finish_configuration()
    end
  end
  for path, bps in pairs(sources) do
    pending = pending + 1
    self:set_breakpoints(path, bps, done)
  end
  done()
end

function Session:_finish_configuration()
  local function after_exceptions()
    if self.capabilities.supportsConfigurationDoneRequest then
      self:request("configurationDone", nil, function()
        self.initialized = true
        if self.handlers.on_state then
          self.handlers.on_state("running")
        end
      end)
    else
      self.initialized = true
      if self.handlers.on_state then
        self.handlers.on_state("running")
      end
    end
  end
  -- Default exception filters off (a faithful minimal default; a UI to pick filters
  -- is deferred). Only send if the adapter advertises any.
  if self.capabilities.exceptionBreakpointFilters then
    self:request("setExceptionBreakpoints", { filters = {} }, after_exceptions)
  else
    after_exceptions()
  end
end

-- Send setBreakpoints for one source file. `bps` is a list of `{ line, condition?,
-- logMessage? }`. `cb(err, body)` optional.
function Session:set_breakpoints(path, bps, cb)
  local points = {}
  for _, bp in ipairs(bps) do
    points[#points + 1] = {
      line = bp.line,
      condition = bp.condition,
      logMessage = bp.logMessage,
      hitCondition = bp.hitCondition,
    }
  end
  self:request("setBreakpoints", {
    source = { path = path, name = path:match("[^/]+$") or path },
    breakpoints = points,
    sourceModified = false,
  }, cb)
end

-- ----- the stopped drill-down ------------------------------------------------

function Session:_on_stopped(body)
  self.stopped_thread_id = body.threadId
  -- threads → stackTrace(top thread) → scopes(top frame) → variables, each feeding
  -- the next, then hand the assembled snapshot to the UI listener.
  self:request("threads", nil, function(_, tbody)
    self.threads = {}
    for _, t in ipairs((tbody or {}).threads or {}) do
      self.threads[t.id] = t
    end
    local tid = body.threadId
      or (tbody and tbody.threads and tbody.threads[1] and tbody.threads[1].id)
    if not tid then
      if self.handlers.on_stopped then
        self.handlers.on_stopped(body, { frames = {} })
      end
      return
    end
    self.stopped_thread_id = tid
    self:request("stackTrace", { threadId = tid, startFrame = 0, levels = 20 }, function(_, sbody)
      local frames = (sbody or {}).stackFrames or {}
      self.current_frame = frames[1]
      if self.handlers.on_stopped then
        self.handlers.on_stopped(body, { frames = frames, threadId = tid })
      end
    end)
  end)
end

-- Resolve the scopes + variables for a frame, calling `cb(scopes)` where each scope
-- carries a resolved `variables` list (one level deep — nested structures expand on
-- demand via `variables(ref)`).
function Session:frame_scopes(frame_id, cb)
  self:request("scopes", { frameId = frame_id }, function(_, body)
    local scopes = (body or {}).scopes or {}
    local remaining = #scopes
    if remaining == 0 then
      cb({})
      return
    end
    for _, scope in ipairs(scopes) do
      self:variables(scope.variablesReference, function(vars)
        scope.variables = vars
        remaining = remaining - 1
        if remaining == 0 then
          cb(scopes)
        end
      end)
    end
  end)
end

-- Fetch the child variables under a `variablesReference` (0 → no children).
function Session:variables(ref, cb)
  if not ref or ref == 0 then
    cb({})
    return
  end
  self:request("variables", { variablesReference = ref }, function(_, body)
    cb((body or {}).variables or {})
  end)
end

-- Evaluate `expr` in the context of `frame_id` (the REPL / hover). `context` is
-- "repl" | "hover" | "watch".
function Session:evaluate(expr, frame_id, context, cb)
  self:request("evaluate", {
    expression = expr,
    frameId = frame_id,
    context = context or "repl",
  }, cb)
end

-- ----- execution control -----------------------------------------------------

local function step(self, command)
  local tid = self.stopped_thread_id
  if not tid then
    notify(self, "nxvim-dap: not stopped", 3)
    return
  end
  self.stopped_thread_id = nil
  self.current_frame = nil
  if self.handlers.on_continued then
    self.handlers.on_continued({})
  end
  self:request(command, { threadId = tid }, function(err)
    if err then
      notify(self, ("nxvim-dap: %s failed: %s"):format(command, tostring(err.message)), 4)
    end
  end)
end

function Session:continue()
  step(self, "continue")
end
function Session:step_over()
  step(self, "next")
end
function Session:step_into()
  step(self, "stepIn")
end
function Session:step_out()
  step(self, "stepOut")
end

function Session:pause(thread_id)
  self:request("pause", { threadId = thread_id or next(self.threads) }, function(err)
    if err then
      notify(self, "nxvim-dap: pause failed: " .. tostring(err.message), 4)
    end
  end)
end

-- Gracefully end the session: `disconnect` (terminate the debuggee), then close the
-- transport once the adapter acknowledges (or immediately if it never does).
function Session:disconnect(opts)
  opts = opts or {}
  if self.terminated then
    self.transport.close()
    return
  end
  local closed = false
  local function close()
    if not closed then
      closed = true
      self.transport.close()
    end
  end
  self:request("disconnect", {
    restart = false,
    terminateDebuggee = opts.terminate ~= false,
  }, close)
  -- Don't wait forever on a wedged adapter.
  nx.timer(close, 500)
end

-- ----- spawning a real adapter child -----------------------------------------

-- Resolve an adapter spec (a table, or a `function(cb, config)` resolver) to a
-- concrete `{ type, command, args, env, cwd }`, calling `cb(adapter)`.
local function resolve_adapter(adapter, config, cb)
  if type(adapter) == "function" then
    adapter(cb, config)
  else
    cb(adapter)
  end
end

-- Fire on_terminated once (guarding the flag), used when the transport dies.
local function terminate_once(session, body)
  if not session.terminated then
    session.terminated = true
    if session.handlers.on_terminated then
      session.handlers.on_terminated(body or {})
    end
  end
end

-- An EXECUTABLE adapter: a duplex stdio child over nx.process. Its stdout is the DAP
-- wire; stderr is surfaced as output; its exit ends the session. Starts the session
-- immediately (writes buffer in the actor until the child is up).
local function connect_executable(session, resolved, config, handlers)
  local proc = nx.process.open({
    cmd = resolved.command,
    args = resolved.args or {},
    cwd = resolved.cwd,
    env = resolved.env,
    on_stdout = function(chunk)
      session:feed(chunk)
    end,
    on_stderr = function(chunk)
      -- Adapter diagnostics: surface on the REPL/output stream, not as errors
      -- (many adapters log routine info to stderr).
      if handlers.on_output then
        handlers.on_output("stderr", chunk)
      end
    end,
    on_exit = function(code)
      terminate_once(session, { exitCode = code })
    end,
  })
  session._chan = proc
  session._close = function()
    proc:kill()
  end
  session:start(config)
end

-- A SERVER adapter: optionally launch the adapter executable (it opens the port),
-- then connect over nx.socket — retrying while the executable comes up — and start
-- the session once connected. The DAP wire is the socket; the executable's std streams
-- are surfaced as output.
local function connect_server(session, resolved, config, handlers)
  local host = resolved.host or "127.0.0.1"
  local port = resolved.port
  local opts = resolved.options or {}
  local max_retries = opts.max_retries or 14
  local retry_delay = opts.retry_delay or 250 -- ms

  local exe
  if resolved.executable then
    exe = nx.process.open({
      cmd = resolved.executable.command,
      args = resolved.executable.args or {},
      cwd = resolved.executable.cwd,
      env = resolved.executable.env,
      on_stdout = function(chunk)
        if handlers.on_output then
          handlers.on_output("stdout", chunk)
        end
      end,
      on_stderr = function(chunk)
        if handlers.on_output then
          handlers.on_output("stderr", chunk)
        end
      end,
      on_exit = function(code)
        terminate_once(session, { exitCode = code })
      end,
    })
  end

  local attempt = 0
  local function try_connect()
    attempt = attempt + 1
    local connected = false
    local sock
    sock = nx.socket.connect({
      host = host,
      port = port,
      on_connect = function()
        connected = true
        session._chan = sock
        session._close = function()
          sock:close()
          if exe then
            exe:kill()
          end
        end
        session:start(config)
      end,
      on_data = function(chunk)
        session:feed(chunk)
      end,
      on_close = function(err)
        if connected then
          -- Established then dropped → the session ended.
          terminate_once(session, {})
        elseif attempt < max_retries and not session.terminated then
          -- Not up yet: retry after a short delay (the executable is still binding).
          nx.timer(try_connect, retry_delay)
        else
          notify(
            session,
            ("nxvim-dap: could not connect to %s:%d (%s)"):format(host, port, tostring(err)),
            4
          )
          if exe then
            exe:kill()
          end
          terminate_once(session, {})
        end
      end,
    })
  end
  try_connect()
end

-- Spawn/connect the adapter for `config` and start the session. `adapter` is looked
-- up by `config.type` by the caller (a table or a `function(cb, config)` resolver).
-- Returns the session synchronously; the transport comes up async.
function M.spawn(adapter, config, handlers)
  local session
  local transport = {
    write = function(data)
      if session and session._chan then
        session._chan:write(data)
      end
    end,
    close = function()
      if session and session._close then
        session._close()
      end
    end,
  }
  session = M.new(transport, handlers)

  resolve_adapter(adapter, config, function(resolved)
    local ok, err = pcall(require("nxvim-dap.config").validate_adapter, resolved, config.type)
    if not ok then
      notify(session, tostring(err), 4)
      terminate_once(session, {})
      return
    end
    if (resolved.type or "executable") == "server" then
      connect_server(session, resolved, config, handlers)
    else
      connect_executable(session, resolved, config, handlers)
    end
  end)

  return session
end

return M
