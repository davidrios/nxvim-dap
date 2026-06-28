-- The :Dap* user commands. Three take an optional argument; each declares it via the
-- `usage` signature, which heads the `:Dap<Tab>` completion docs pane (`:DapContinue
-- [config]`) exactly like a built-in command — so the parameter is discoverable
-- in-editor, not only in the help file.

local dap = require("nxvim-dap")

nx.test.describe("nxvim-dap commands", function()
  nx.test.before_each(function()
    dap.setup({})
  end)

  nx.test.it("declares the argument signature of every parametered command", function()
    local cmds = nx.user_command.get()
    local function usage(name)
      return cmds[name] and cmds[name].usage or ""
    end

    -- The three commands that accept an argument advertise its signature.
    nx.test.expect(usage("DapContinue")).to_be("[config]")
    nx.test.expect(usage("DapEval")).to_be("[expr]")
    nx.test.expect(usage("DapWatch")).to_be("[expr]")

    -- A no-argument command carries no usage signature.
    nx.test.expect(usage("DapRestart")).to_be("")

    -- DapContinue completes configuration names for `<Tab>`.
    nx.test.expect(cmds["DapContinue"].complete).never.to_be_nil()
  end)
end)
