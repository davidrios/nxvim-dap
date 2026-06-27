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
    -- A fake session mirroring how debugpy answers `os.get`: it completes the attribute
    -- after the dot, returning the member name (`getcwd`) with a 0-based replace span
    -- covering the `get` qualifier (start=3 is the `g`, length=3). debugpy emits a
    -- 0-based `start` even though we negotiated columnsStartAt1=true, so the plugin uses
    -- it as-is — a stray `- 1` here would replace `.get` and yield `osgetcwd`.
    local fake = {
      current_frame = { id = 1 },
      completions = function(_, _text, _col, _frame, cb)
        cb(nil, { { label = "getcwd", text = "getcwd", start = 3, length = 3 } })
      end,
      evaluate = function(_, _expr, _frame, _ctx, cb)
        cb(nil, { result = "<cwd>" })
      end,
    }
    repl.open()
    repl.set_session(fake)

    -- Open the dap> prompt, type a partial member access, complete it (<Tab> opens the
    -- wildmenu, <Tab> selects the row), and submit — the range replaces only the `get`
    -- qualifier, keeping the `os.`, so the echoed expression is the whole member access.
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

  nx.test.it("completes after an open paren without eating it", function(t)
    -- Regression: typing `abs(` then completing the argument must keep the `(`. debugpy,
    -- asked to complete at the cursor of `abs(`, returns names with a 0-based insert
    -- point AT the cursor (start=4 — just past the paren — length=0, nothing overwritten).
    -- The old `start - 1` shifted that to offset 3, dropping the completion in front of
    -- the `(` instead of after it. The completion must land after the paren.
    local fake = {
      current_frame = { id = 1 },
      completions = function(_, _text, _col, _frame, cb)
        cb(nil, { { label = "xs", text = "xs", start = 4, length = 0 } })
      end,
      evaluate = function(_, _expr, _frame, _ctx, cb)
        cb(nil, { result = "1" })
      end,
    }
    repl.open()
    repl.set_session(fake)

    t:feed("<CR>")
    t:feed("abs(")
    t:feed("<Tab>")
    t:feed("<Tab>")
    t:feed("<CR>")
    t:sleep(80)

    local buf = repl.bufnr()
    local lines = buf and nx.buf.lines(buf, 0, -1, false) or {}
    local echoed = false
    for _, l in ipairs(lines) do
      if l == "> abs(xs" then
        echoed = true
      end
    end
    nx.test.expect(echoed).to_be_truthy()
  end)
end)
