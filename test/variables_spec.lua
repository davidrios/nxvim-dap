-- Launch-config variable expansion (variables.lua): the `${...}` substitution and the
-- callable dynamic-value form, resolved against a real editor context (a temp file
-- opened in a temp cwd). Drives the expander directly; the end-to-end flow (the adapter
-- actually receiving the expanded path) is covered in e2e_spec.

local dap = require("nxvim-dap")
local variables = require("nxvim-dap.variables")

-- Open `fname` inside `dir`, making `dir` the working directory, so the file/workspace
-- variables resolve deterministically. Returns the file path.
local function open_in(t, dir, fname, body)
  local f = dir .. "/" .. fname
  nx.await(nx.fs.write(f, body or "x = 1\n"))
  t:cmd("cd " .. dir)
  t:cmd("edit " .. f)
  return f
end

nx.test.describe("nxvim-dap.variables expansion", function()
  nx.test.before_each(function()
    dap.setup({})
  end)

  nx.test.it("expands the file-derived variables against the current buffer", function(t)
    local dir = nx.test.tempdir()
    local f = open_in(t, dir, "main.py")
    local abs = dap.signs.abspath(f)
    local out = variables.expand({
      program = "${file}",
      base = "${fileBasename}",
      noext = "${fileBasenameNoExtension}",
      dirn = "${fileDirname}",
      ext = "${fileExtname}",
      rel = "${relativeFile}",
    })
    nx.test.expect(out.program).to_be(abs)
    nx.test.expect(out.base).to_be("main.py")
    nx.test.expect(out.noext).to_be("main")
    nx.test.expect(out.ext).to_be("py")
    nx.test.expect(out.dirn).to_be(vim.fn.fnamemodify(abs, ":h"))
    nx.test.expect(out.rel).to_be("main.py") -- file is under the cwd we cd'd into
  end)

  nx.test.it("expands the workspace / cwd variables", function(t)
    local dir = nx.test.tempdir()
    open_in(t, dir, "a.py")
    local cwd = vim.fn.getcwd()
    local out = variables.expand({
      wsf = "${workspaceFolder}",
      wsfb = "${workspaceFolderBasename}",
      cwd = "${cwd}",
    })
    nx.test.expect(out.wsf).to_be(cwd)
    nx.test.expect(out.cwd).to_be(cwd)
    nx.test.expect(out.wsfb).to_be(vim.fn.fnamemodify(cwd, ":t"))
  end)

  nx.test.it("expands ${env:NAME} (and empties an unset one)", function(t)
    open_in(t, nx.test.tempdir(), "a.py")
    local out = variables.expand({
      p = "${env:PATH}",
      missing = "${env:NXVIM_DAP_DEFINITELY_UNSET}",
    })
    nx.test.expect(out.p).to_be(os.getenv("PATH"))
    nx.test.expect(out.missing).to_be("")
  end)

  nx.test.it("leaves an unrecognised ${...} untouched and reports it", function(t)
    open_in(t, nx.test.tempdir(), "a.py")
    local out, unknown = variables.expand({ weird = "before-${nope}-after" })
    nx.test.expect(out.weird).to_be("before-${nope}-after")
    local found = false
    for _, n in ipairs(unknown) do
      if n == "nope" then
        found = true
      end
    end
    nx.test.expect(found).to_be(true)
  end)

  nx.test.it("recurses into args lists and nested tables", function(t)
    local dir = nx.test.tempdir()
    local f = open_in(t, dir, "main.py")
    local abs = dap.signs.abspath(f)
    local out = variables.expand({
      args = { "--file", "${file}", "${fileBasename}" },
      env = { ROOT = "${workspaceFolder}" },
      n = 5,
    })
    nx.test.expect(out.args[2]).to_be(abs)
    nx.test.expect(out.args[3]).to_be("main.py")
    nx.test.expect(out.env.ROOT).to_be(vim.fn.getcwd())
    nx.test.expect(out.n).to_be(5) -- non-strings pass through untouched
  end)

  nx.test.it("calls a dynamic-value function and expands its result", function(t)
    local dir = nx.test.tempdir()
    local f = open_in(t, dir, "main.py")
    local abs = dap.signs.abspath(f)
    local out = variables.expand({
      program = function()
        return "${file}"
      end, -- returns a ${...} string → expanded in turn
      literal = function()
        return "/computed/path"
      end,
      args = {
        function()
          return "${fileBasename}"
        end,
      },
    })
    nx.test.expect(out.program).to_be(abs)
    nx.test.expect(out.literal).to_be("/computed/path")
    nx.test.expect(out.args[1]).to_be("main.py")
  end)

  nx.test.it("fails loud when a dynamic-value function errors", function(t)
    open_in(t, nx.test.tempdir(), "a.py")
    local ok, err = pcall(variables.expand, {
      program = function()
        error("boom")
      end,
    })
    nx.test.expect(ok).to_be(false)
    nx.test.expect(tostring(err):find("boom", 1, true)).never.to_be_nil()
  end)
end)
