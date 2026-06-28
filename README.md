# nxvim-dap

A **Debug Adapter Protocol** client for [nxvim](https://github.com/davidrios/nxvim) —
the nxvim sibling of [nvim-dap](https://github.com/mfussenegger/nvim-dap).

It is built entirely on the native `nx.*` plugin API (ADR 0002): no buffer-mutation
hacks, no bespoke rendering loop. A debug adapter is a long-lived child that speaks
[Content-Length-framed JSON](https://microsoft.github.io/debug-adapter-protocol/) over
stdio — exactly like a language server — so nxvim-dap rides nxvim's **duplex process**
primitive `nx.process`, frames the wire itself, paints breakpoint / stopped signs with
extmarks, and renders the scopes/stack sidebar and REPL on read-only `nx.view` docks.
The breakpoints live in real editor buffers; the panels own their own lines. That's the
point: a real debugger front end, written the way a plugin author would write it.

```
  ●  def fib(n):
  ▶      a, b = 0, 1          ← stopped here
         for _ in range(n):

  ┌ SCOPES ───────────────┐
  │ Locals                │
  │   x = 42              │
  └───────────────────────┘
```

## Why `nx.process`

The keystone is nxvim's `nx.process.open` — a **bidirectional** child whose stdin stays
open for writes and whose stdout streams back as raw bytes. Neither `nx.run` (one-shot)
nor `nx.run_stream` (read-only, newline-split) can carry a framed protocol, so this is
the same transport an in-Lua language-server client would need. nxvim-dap is the first
consumer.

Adapters that speak over a TCP socket (`type = "server"`, e.g. codelldb, js-debug, or
delve when run as a server) ride nxvim's `nx.socket.connect` — a duplex TCP sibling of
`nx.process`. nxvim-dap optionally launches the adapter executable (it opens the port),
then connects to `host:port`, retrying while it comes up. So both adapter kinds work.

## Features

- **Real adapter transport** — launch/attach an executable debug adapter over a duplex
  stdio pipe (`nx.process`), with the full DAP handshake (initialize → launch/attach →
  breakpoints → configurationDone).
- **Breakpoints** — toggle (`<leader>db`), conditional (`<leader>dB`), and log points,
  plus a full **edit** flow (`<leader>de`) for the condition / hit count / log message,
  shown as gutter signs in the source buffer and synced live to a running session.
  `:DapBreakpoints` lists them all in a **live** named list — its own dock tab, kept even
  when you close the window it opened from (select an entry to jump to it; it refreshes in
  place as you add or remove breakpoints). In a `--workspace` session
  they're saved to the workspace's plugin shada and restored next time the project is
  opened.
- **Exception breakpoints** — pick the adapter's exception filters (e.g. *raised* /
  *uncaught*) from a checkbox section in the sidebar; the choice is seeded at launch,
  pushed live, and persists across restarts.
- **Stepping & restart** — continue / step over / into / out / **restart** (`<F6>`, via
  the adapter's restart request or a terminate-and-relaunch), with the stopped line
  marked by a sign + line highlight and the editor jumping to the frame's source.
- **Sidebar** — a dock showing the stopped thread's **stack frames**, the selected
  frame's **scopes / variables**, **watch expressions**, the **exception filters**, and
  (with more than one session) a **sessions switcher**. `<CR>` expands a variable / jumps
  to a frame / toggles a filter / switches session; `e` **edits a value** (`setVariable`
  / `setExpression`); `a` adds a watch, `x` removes one, `r` refreshes.
- **Multiple concurrent sessions** — run several debuggees at once; the panels follow
  the session that stops, and `:DapSessions` switches the active one.
- **REPL / console** — the adapter's `output` events plus an `evaluate` prompt that runs
  expressions in the stopped frame. The prompt **stays open** like a real REPL — each
  `<CR>` evaluates the line and reopens for the next; `<Esc>` closes it — with
  readline-style history (`<Up>`/`<Down>` recall the session's past expressions) and
  `<Tab>` autocomplete (the adapter's `completions` request, shown in an inline wildmenu
  with a side-docs pane).
- **nvim-dap parity** — the same `adapters` / `configurations` two-table model, so a
  ported debug setup reads almost identically.
- **Extensible** — overridable highlights, rebindable keys, a public API, and the
  `adapters` / `configurations` registries.

## Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
nx.plugins({
  {
    "davidrios/nxvim-dap",
    config = function()
      local dap = require("nxvim-dap")
      dap.setup({})

      -- An adapter (HOW to reach a debug adapter) …
      dap.adapters.python = {
        type = "executable",
        command = "python3",
        args = { "-m", "debugpy.adapter" },
      }
      -- … and a configuration per filetype (WHAT to debug).
      dap.configurations.python = {
        {
          type = "python",
          request = "launch",
          name = "Launch file",
          program = "${file}",
        },
      }
    end,
  },
})
```

Run `:PluginSync` to clone it, then press `<F5>` (or `:DapContinue`) in a Python file.

> The REPL prompt and breakpoint conditions need nxvim's `nx.ui.input`; the adapter
> transport needs the native `nx.process` (a desktop/daemon session, not the serverless
> wasm build).

## Configuration

`setup()` takes an optional table; the defaults are:

```lua
require("nxvim-dap").setup({
  signs = {
    breakpoint = { text = "●", hl = "NxDapBreakpoint" },
    breakpoint_condition = { text = "◆", hl = "NxDapBreakpointCondition" },
    log_point = { text = "◇", hl = "NxDapLogPoint" },
    stopped = { text = "▶", hl = "NxDapStopped", line_hl = "NxDapStoppedLine" },
  },
  sidebar = {
    position = "right", width = 40, open_on_stopped = true,
    -- buffer-local keys inside the sidebar (false disables one):
    mappings = { edit = "e", add_watch = "a", remove = "x", refresh = "r" },
  },
  repl = { position = "bottom", height = 12, open_on_start = true },
  mappings = { ... },        -- action → key (see below; false disables one / all)
  jump_to_stopped = true,    -- jump the editor to the stopped frame
  highlights = {},           -- highlight-group overrides
  adapters = {},             -- seed the adapter registry (or assign dap.adapters.*)
  configurations = {},       -- seed the configuration registry per filetype
})
```

`setup()` is re-runnable — calling it again is a full reconfigure (merged fresh from the
defaults).

### Adapters and configurations

Exactly nvim-dap's model:

```lua
local dap = require("nxvim-dap")

-- An adapter is an executable (a stdio child) …
dap.adapters.lldb = { type = "executable", command = "lldb-dap" }

-- … a TCP server the client connects to (optionally launching it first) …
dap.adapters.codelldb = {
  type = "server",
  host = "127.0.0.1",
  port = 13000,
  executable = { command = "codelldb", args = { "--port", "13000" } },
  -- options = { max_retries = 14, retry_delay = 250 },  -- while the port comes up
}

-- … or a function resolving one dynamically:
dap.adapters.python = function(callback, _config)
  callback({ type = "executable", command = "python3", args = { "-m", "debugpy.adapter" } })
end

-- Configurations are keyed by filetype; each names the adapter via `type`.
dap.configurations.c = {
  { type = "lldb", request = "launch", name = "Launch", program = "./a.out" },
}
```

When you `:DapContinue` with no running session, nxvim-dap picks a configuration for the
current buffer's filetype (prompting if there's more than one).

### Variable expansion

Configuration string values are expanded against the current editor context the moment a
session starts, so the nvim-dap idiom works as written:

| Variable | Expands to |
| --- | --- |
| `${file}` | the current buffer's absolute path |
| `${fileBasename}` / `${fileBasenameNoExtension}` | its filename, with / without extension |
| `${fileDirname}` / `${fileExtname}` | its directory / extension |
| `${relativeFile}` / `${relativeFileDirname}` | the file (or its dir) relative to the cwd |
| `${workspaceFolder}` / `${workspaceFolderBasename}` / `${cwd}` | the working directory / its basename |
| `${env:NAME}` | the `NAME` environment variable (`""` when unset) |

Expansion recurses into nested tables and `args` lists. A value may also be a **function
returning a string** — called synchronously at launch, its result expanded in turn — for a
path computed dynamically:

```lua
program = function() return vim.fn.getcwd() .. "/build/app" end  -- synchronous: return a string
```

The interactive VSCode forms work too (resolved with a prompt at launch):

| Token | Resolves by |
| --- | --- |
| `${input:id}` | looking up `config.inputs[id]` and prompting per its `type` |
| `${command:id}` | running a handler registered with `dap.register_command(id, fn)` |

An `input` is the launch.json shape — `{ id, type, description?, default?, options?,
command?, args? }` — with `type` one of `promptString` (a text prompt), `pickString` (a
menu over `options`), or `command` (run a registered command). Each id is prompted once per
launch. A `${command:id}` handler `fn(args, config)` returns a string (or a promise of
one). A missing definition, an unsupported type, or a cancelled prompt aborts the launch;
any other unrecognised `${...}` is left as-is and a warning is shown.

```lua
dap.register_command("pickProcess", function()
  return tostring(vim.fn.getpid()) -- or return a promise for an async pick
end)

dap.configurations.python = {
  { type = "python", request = "launch", name = "Launch file", program = "${file}" },
  {
    type = "python", request = "launch", name = "Launch with args",
    program = "${file}",
    args = "${input:scriptArgs}",
    inputs = {
      { id = "scriptArgs", type = "promptString", description = "Arguments", default = "" },
    },
  },
}
```

### Commands

| Command                    | Action                                    |
| -------------------------- | ----------------------------------------- |
| `:DapContinue [config]`    | start debugging / resume (`<Tab>` completes a config name) |
| `:DapStepOver`             | step over                                 |
| `:DapStepInto`             | step into                                 |
| `:DapStepOut`              | step out                                  |
| `:DapPause`                | pause a running thread                    |
| `:DapRestart`              | restart the active session                |
| `:DapTerminate`            | end the active session                    |
| `:DapTerminateAll`         | end every session                         |
| `:DapSessions`             | switch the active session                 |
| `:DapToggleBreakpoint`     | toggle a breakpoint at the cursor         |
| `:DapBreakpointCondition`  | set a conditional breakpoint              |
| `:DapLogPoint`             | set a log point                           |
| `:DapEditBreakpoint`       | edit condition / hit count / log message  |
| `:DapBreakpoints`          | list every breakpoint in a named list     |
| `:DapClearBreakpoints`     | remove every breakpoint                   |
| `:DapExceptionBreakpoints` | pick exception breakpoint filters         |
| `:DapWatch [expr]`         | add a watch expression (no arg → prompt)  |
| `:DapWatchClear`           | remove every watch expression             |
| `:DapReplToggle`           | toggle the REPL / console                 |
| `:DapSidebarToggle`        | toggle the scopes / stack sidebar         |
| `:DapEval [expr]`          | evaluate an expression in the stopped frame |

### Default key bindings

| Key          | Action                | Key          | Action               |
| ------------ | --------------------- | ------------ | -------------------- |
| `<F5>`       | continue / start      | `<leader>db` | toggle breakpoint    |
| `<F10>`      | step over             | `<leader>dB` | conditional breakpoint |
| `<F11>`      | step into             | `<leader>de` | edit breakpoint      |
| `<F12>`      | step out              | `<leader>dr` | toggle REPL          |
| `<F6>`       | restart               | `<leader>du` | toggle sidebar       |
| `<leader>dx` | terminate             |              |                      |

Inside the **sidebar** these buffer-local keys act on the row under the cursor (defaults,
configurable via `opts.sidebar.mappings`): `<CR>` expand / jump / toggle filter / switch
session, `e` edit a value, `a` add a watch, `x` remove the watch, `r` refresh. A
**double-click** on a row is the mouse form of `<CR>` (a single click positions the cursor).

Rebind or disable any of them through `opts.mappings` (a value of `false` on an entry,
or `mappings = false` for all):

```lua
require("nxvim-dap").setup({
  mappings = { continue = "<F9>", repl_toggle = false },
})
```

## API

`require("nxvim-dap")` exposes:

| Function                        | What it does                                  |
| ------------------------------- | --------------------------------------------- |
| `setup(opts)`                   | configure (re-runnable)                        |
| `continue()`                    | start debugging / resume                       |
| `run(config)`                   | start a specific launch/attach configuration (a new concurrent session) |
| `register_command(id, fn)`      | register a `${command:id}` handler             |
| `restart()`                     | restart the active session                     |
| `step_over()` / `step_into()` / `step_out()` | stepping                          |
| `pause()` / `terminate()` / `terminate_all()` | pause / end one / end all       |
| `session()` / `sessions()`      | the active `Session` (or `nil`) / every live session |
| `set_active_session(s)` / `pick_session()` | switch the active session (direct / prompt) |
| `toggle_breakpoint()`           | toggle a breakpoint at the cursor              |
| `set_breakpoint_condition()` / `set_log_point()` | prompt + set a conditional / log point |
| `edit_breakpoint()`             | edit condition / hit count / log message at the cursor |
| `clear_breakpoints()`           | remove all breakpoints                         |
| `add_watch(expr)` / `clear_watches()` | add a watch (no arg → prompt) / remove all |
| `set_exception_breakpoints()`   | open the exception-filter picker               |
| `toggle_exception_filter(id)` / `is_exception_selected(id)` | toggle / query a filter |
| `repl_toggle()` / `sidebar_toggle()` | toggle the panels                         |
| `eval(expr)`                    | evaluate in the stopped frame (REPL)           |
| `adapters` / `configurations`   | the registries (assign into them directly)     |

## Highlights

The plugin defines these groups as a **fallback** (a colorscheme or your
`opts.highlights` override wins):

| Group                     | What it colors                 |
| ------------------------- | ------------------------------ |
| `NxDapBreakpoint`         | a breakpoint sign              |
| `NxDapBreakpointCondition`| a conditional breakpoint sign  |
| `NxDapLogPoint`           | a log-point sign               |
| `NxDapStopped` / `…StoppedLine` | the stopped sign / line  |
| `NxDapUIScope` / `…Thread` / `…Frame` / `…FrameCurrent` | sidebar headers / frames |
| `NxDapUIVarName` / `…VarType` / `…Value` | sidebar variables |
| `NxDapReplPrompt` / `…ReplError` | the REPL prompt / errors |

```lua
require("nxvim-dap").setup({
  highlights = { NxDapStopped = { fg = "#ffd54f", bold = true } },
})
```

## Trying it locally

This repo ships a runnable demo with a **self-contained mock adapter** (no debugger
install needed):

```sh
NXVIM_CONFIG=examples nxvim examples/sample/fib.py
```

(run from the repo root). Toggle a breakpoint with `<leader>db`, hit `<F5>`, and watch
the stopped sign, the sidebar, and the REPL.

## Tests

The plugin carries a Lua test suite (`test/*_spec.lua`) on nxvim's native `nx.test`
framework. The protocol logic (framing, the session handshake, the stopped drill-down,
stepping) is covered against a fake transport; one end-to-end spec drives the whole
client against a **real adapter subprocess** (`test/support/mock_adapter.py`) over
`nx.process`. Run them headlessly:

```sh
nxvim --test-plugin .
```

(The end-to-end spec needs `python3` for the mock adapter; the rest are pure Lua.)

## License

MIT © David Rios
