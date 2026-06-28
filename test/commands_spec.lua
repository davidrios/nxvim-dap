-- The :Dap* user commands. Three take an optional argument; their `desc` (the text
-- the command-line completer shows for `:Dap<Tab>`) must name that argument so the
-- parameter is discoverable in-editor, not only in the help file.

local dap = require("nxvim-dap")

nx.test.describe("nxvim-dap commands", function()
  nx.test.before_each(function()
    dap.setup({})
  end)

  nx.test.it("documents the argument of every parametered command in its desc", function()
    local cmds = nx.user_command.get()
    local function desc(name)
      return cmds[name] and cmds[name].desc or ""
    end

    -- The three commands that accept an argument advertise it.
    nx.test.expect(desc("DapContinue"):find("[config]", 1, true)).never.to_be_nil()
    nx.test.expect(desc("DapEval"):find("[expr]", 1, true)).never.to_be_nil()
    nx.test.expect(desc("DapWatch"):find("[expr]", 1, true)).never.to_be_nil()

    -- DapContinue completes configuration names for `<Tab>`.
    nx.test.expect(cmds["DapContinue"].complete).never.to_be_nil()
  end)
end)
