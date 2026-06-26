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

> Adapters that only speak over a TCP socket (`type = "server"`) are **not** supported
> yet — nxvim exposes no socket primitive, so such an adapter fails *loud* at config
> time rather than silently never connecting. `type = "executable"` (a stdio child) is
> the supported transport, which covers debugpy, delve (`dlv dap`), and most adapters.

## Features

- **Real adapter transport** — launch/attach an executable debug adapter over a duplex
  stdio pipe (`nx.process`), with the full DAP handshake (initialize → launch/attach →
  breakpoints → configurationDone).
- **Breakpoints** — toggle (`<leader>db`), conditional (`<leader>dB`), and log points,
  shown as gutter signs in the source buffer and synced live to a running session.
- **Stepping** — continue / step over / into / out, with the stopped line marked by a
  sign + line highlight and the editor jumping to the frame's source.
- **Sidebar** — a dock showing the stopped thread's **stack frames** and the selected
  frame's **scopes / variables**; `<CR>` on a frame jumps to it, `<CR>` on a structured
  variable expands it (lazily fetched).
- **REPL / console** — the adapter's `output` events plus an `evaluate` prompt that runs
  expressions in the stopped frame.
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
  sidebar = { position = "right", width = 40, open_on_stopped = true },
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

### Commands

| Command                    | Action                                    |
| -------------------------- | ----------------------------------------- |
| `:DapContinue`             | start debugging / resume                  |
| `:DapStepOver`             | step over                                 |
| `:DapStepInto`             | step into                                 |
| `:DapStepOut`              | step out                                  |
| `:DapPause`                | pause a running thread                    |
| `:DapTerminate`            | end the session                           |
| `:DapToggleBreakpoint`     | toggle a breakpoint at the cursor         |
| `:DapBreakpointCondition`  | set a conditional breakpoint              |
| `:DapLogPoint`             | set a log point                           |
| `:DapClearBreakpoints`     | remove every breakpoint                   |
| `:DapReplToggle`           | toggle the REPL / console                 |
| `:DapSidebarToggle`        | toggle the scopes / stack sidebar         |
| `:DapEval [expr]`          | evaluate an expression in the stopped frame |

### Default key bindings

| Key          | Action                | Key          | Action               |
| ------------ | --------------------- | ------------ | -------------------- |
| `<F5>`       | continue / start      | `<leader>db` | toggle breakpoint    |
| `<F10>`      | step over             | `<leader>dB` | conditional breakpoint |
| `<F11>`      | step into             | `<leader>dr` | toggle REPL          |
| `<F12>`      | step out              | `<leader>du` | toggle sidebar       |
| `<leader>dx` | terminate             |              |                      |

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
| `run(config)`                   | start a specific launch/attach configuration   |
| `step_over()` / `step_into()` / `step_out()` | stepping                          |
| `pause()` / `terminate()`       | pause / end                                    |
| `toggle_breakpoint()`           | toggle a breakpoint at the cursor              |
| `set_breakpoint_condition()`    | prompt for a condition + set                   |
| `clear_breakpoints()`           | remove all breakpoints                         |
| `repl_toggle()` / `sidebar_toggle()` | toggle the panels                         |
| `eval(expr)`                    | evaluate in the stopped frame (REPL)           |
| `session()`                     | the active `Session`, or `nil`                 |
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
