-- The config surface: the merge semantics and the validation that fails LOUD on a
-- transport / shape nxvim-dap can't honor (no silent stubs). Pure logic.

local config = require("nxvim-dap.config")

nx.test.describe("nxvim-dap.config merge", function()
  nx.test.it("overrides scalars and recurses tables, replacing lists wholesale", function()
    local base = config.defaults()
    local merged = config.merge(base, {
      sidebar = { width = 60 },
      mappings = { continue = "<F9>" },
    })
    nx.test.expect(merged.sidebar.width).to_be(60)
    nx.test.expect(merged.sidebar.position).to_be("right") -- untouched default kept
    nx.test.expect(merged.mappings.continue).to_be("<F9>")
    nx.test.expect(merged.mappings.step_over).to_be("<F10>") -- sibling default kept
  end)

  nx.test.it("a list value replaces rather than positionally merging", function()
    local merged = config.merge({ args = { "a", "b", "c" } }, { args = { "x" } })
    nx.test.expect(#merged.args).to_be(1)
    nx.test.expect(merged.args[1]).to_be("x")
  end)
end)

nx.test.describe("nxvim-dap.config validation", function()
  nx.test.it("accepts an executable adapter", function()
    nx.test
      .expect(function()
        config.validate_adapter({ type = "executable", command = "debugpy" }, "python")
      end).never
      .to_error()
  end)

  nx.test.it("defaults a bare adapter to executable", function()
    nx.test
      .expect(function()
        config.validate_adapter({ command = "lldb-vscode" }, "cpp")
      end).never
      .to_error()
  end)

  nx.test.it("rejects a server adapter loud (no socket transport)", function()
    nx.test
      .expect(function()
        config.validate_adapter({ type = "server", host = "127.0.0.1", port = 5678 }, "go")
      end)
      .to_error("socket transport")
  end)

  nx.test.it("rejects an executable adapter with no command", function()
    nx.test
      .expect(function()
        config.validate_adapter({ type = "executable" }, "x")
      end)
      .to_error("command")
  end)

  nx.test.it("accepts a resolver function (validated when it produces an adapter)", function()
    nx.test
      .expect(function()
        config.validate_adapter(function() end, "dyn")
      end).never
      .to_error()
  end)

  nx.test.it("requires type/request/name on a configuration", function()
    nx.test
      .expect(function()
        config.validate_configuration({ request = "launch", name = "x" })
      end)
      .to_error("type")
    nx.test
      .expect(function()
        config.validate_configuration({ type = "python", name = "x" })
      end)
      .to_error("launch")
    nx.test
      .expect(function()
        config.validate_configuration({ type = "python", request = "run", name = "x" })
      end)
      .to_error("launch")
  end)

  nx.test.it("accepts a valid launch configuration", function()
    local cfg =
      config.validate_configuration({ type = "python", request = "launch", name = "file" })
    nx.test.expect(cfg.name).to_be("file")
  end)
end)
