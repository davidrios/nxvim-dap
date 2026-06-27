-- The REPL console cursor: after evaluating an expression (entered through the `dap>`
-- prompt that `<CR>` on the view opens), the cursor must land on the newest line — not
-- wherever it was when <CR> was pressed. Regression test for the "cursor jumps up after
-- pressing enter" bug.

local dap = require("nxvim-dap")
local repl = require("nxvim-dap.repl")

nx.test.describe("nxvim-dap repl", function()
  nx.test.before_each(function()
    dap.setup({})
    repl._reset() -- a fresh view + dock, independent of any prior spec's session
  end)

  nx.test.it("keeps the cursor on the newest line after evaluating", function(t)
    repl.open()
    -- Seed scrollback so "the bottom" is well below the top.
    for i = 1, 8 do
      repl.info("line " .. i)
    end
    -- Focus the repl and move the cursor UP — the cursor position from which the user
    -- presses <CR> to evaluate (the bug left it here instead of moving to the result).
    t:feed("gg")
    nx.test.expect(repl.cursor_line()).to_be(1)

    -- Press <CR> to open the `dap>` prompt (the view's on_select), then answer it —
    -- exactly the user's flow ("in the repl and press enter").
    t:feed("<CR>")
    t:feed("1+1<CR>")
    t:sleep(80)

    -- The eval appended lines (the "> 1+1" echo + the no-session notice).
    local buf = repl.bufnr()
    local n = buf and #nx.buf.lines(buf, 0, -1, false) or 0
    nx.test.expect(n).to_be(10) -- 8 seeded + 2 from the eval
    -- …and the cursor is on the newest line, not still at the top (the bug left it up).
    nx.test.expect(repl.cursor_line()).to_be(n)
  end)

  nx.test.it("does not steal focus when output arrives while editing elsewhere", function(t)
    repl.open() -- opens + focuses the repl (bottom dock)
    nx.layer.main() -- leave it for the main editor
    t:sleep(40) -- let the focus switch settle into the mirrors

    local replwin = repl.winid()
    local before = nx.win.current()
    nx.test.expect(before).never.to_be(replwin) -- we're in the main area, not the repl

    -- Adapter output arrives while we're editing elsewhere — it must not pull focus.
    repl.append_output("stdout", "async program output\n")
    t:sleep(40)
    nx.test.expect(nx.win.current()).to_be(before)
  end)

  nx.test.it("completes a REPL expression from the adapter, honoring start/length", function(t)
    -- A fake session whose `completions` returns a target with an explicit replace
    -- range (DAP start is 1-based — columnsStartAt1 — so start=1 means offset 0; length
    -- 6 covers "os.get"). `evaluate` just echoes so the eval can complete.
    local fake = {
      current_frame = { id = 1 },
      completions = function(_, _text, _col, _frame, cb)
        cb(nil, { { label = "os.getcwd", text = "os.getcwd", start = 1, length = 6 } })
      end,
      evaluate = function(_, _expr, _frame, _ctx, cb)
        cb(nil, { result = "<cwd>" })
      end,
    }
    repl.open()
    repl.set_session(fake)

    -- Open the dap> prompt, type a partial member access, complete it (<Tab> opens the
    -- wildmenu, <Tab> selects the row), and submit — the explicit range replaces the
    -- whole "os.get" span, not just the "get" token, so the echoed expression is whole.
    t:feed("<CR>")
    t:feed("os.get")
    t:feed("<Tab>")
    t:feed("<Tab>")
    t:feed("<CR>")
    t:sleep(80)

    local buf = repl.bufnr()
    local lines = buf and nx.buf.lines(buf, 0, -1, false) or {}
    local echoed = false
    for _, l in ipairs(lines) do
      if l == "> os.getcwd" then
        echoed = true
      end
    end
    nx.test.expect(echoed).to_be_truthy()
  end)
end)
