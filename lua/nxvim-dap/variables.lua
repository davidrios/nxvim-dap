-- Launch/attach variable expansion: the `${...}` substitution VSCode and nvim-dap use
-- in debug configurations, resolved against the current editor context the moment a
-- session starts (init.lua calls `M.expand` in `run` before the config is sent to the
-- adapter). Without it, `program = "${file}"` would reach the adapter as the literal
-- 8-character string — so this is what makes the documented nvim-dap-style configs
-- actually run.
--
-- Supported variables (the static nvim-dap core set):
--   ${file}                      the current buffer's absolute path
--   ${fileBasename}              its filename (with extension)
--   ${fileBasenameNoExtension}   its filename without the extension
--   ${fileDirname}               the directory containing it
--   ${fileExtname}               its extension (no dot)
--   ${relativeFile}              the file relative to the working directory
--   ${relativeFileDirname}       the directory of ${relativeFile}
--   ${workspaceFolder}           the working directory (`getcwd`)
--   ${workspaceFolderBasename}   its basename
--   ${cwd}                       the working directory
--   ${env:NAME}                  the NAME environment variable ("" when unset)
--
-- A configuration value may also be a CALLABLE (`function() return "..." end`) — the
-- nvim-dap dynamic-value form, for a path computed at launch (e.g. prompting, or reading
-- a build output). It is invoked at expansion time and its result is expanded in turn (so
-- a function may itself return a `${...}` string). A function that errors fails loud.
--
-- An unrecognised `${...}` is left untouched and reported (init.lua warns) — never
-- silently swallowed, and never prompted for (the VSCode `${input:…}` / `${command:…}`
-- prompts aren't supported; a config needing one fails loud at the warning).

local M = {}

-- The current buffer's absolute file path, or "" when the buffer has no file.
local function current_file()
  local bufnr = nx.buf.current()
  local name = bufnr and nx.buf.name(bufnr)
  if not name or name == "" then
    return ""
  end
  return vim.fn.fnamemodify(name, ":p")
end

-- The file path made relative to `cwd` (a leading `cwd/` stripped), or `file` unchanged
-- when it isn't under `cwd`.
local function relativize(file, cwd)
  if file == "" or cwd == "" then
    return file
  end
  local prefix = cwd:gsub("/+$", "") .. "/"
  if file:sub(1, #prefix) == prefix then
    return file:sub(#prefix + 1)
  end
  return file
end

-- Build the variable table for the current context (file + working directory). All
-- file-derived entries are "" when no file is open, so `${file}`-style tokens expand to
-- empty rather than to a bogus path.
function M.context()
  local file = current_file()
  local cwd = vim.fn.getcwd() or ""
  local rel = relativize(file, cwd)
  local has = file ~= ""
  return {
    file = file,
    fileBasename = has and vim.fn.fnamemodify(file, ":t") or "",
    fileBasenameNoExtension = has and vim.fn.fnamemodify(file, ":t:r") or "",
    fileDirname = has and vim.fn.fnamemodify(file, ":h") or "",
    fileExtname = has and vim.fn.fnamemodify(file, ":e") or "",
    relativeFile = rel,
    relativeFileDirname = rel ~= "" and vim.fn.fnamemodify(rel, ":h") or "",
    workspaceFolder = cwd,
    workspaceFolderBasename = cwd ~= "" and vim.fn.fnamemodify(cwd, ":t") or "",
    cwd = cwd,
  }
end

-- Expand one string against `vars`, collecting any unrecognised `${name}` into `unknown`
-- (a `name -> true` set the caller turns into a warning). `${env:NAME}` resolves first
-- so an env var named like a builtin can't be shadowed. A replacement FUNCTION is used
-- throughout, so a value containing `%` is substituted literally (no capture-ref magic).
local function expand_string(s, vars, unknown)
  s = s:gsub("%${env:([%w_]+)}", function(name)
    return os.getenv(name) or ""
  end)
  s = s:gsub("%${([%w_]+)}", function(name)
    local v = vars[name]
    if v ~= nil then
      return v
    end
    unknown[name] = true
    return "${" .. name .. "}" -- leave it untouched; the caller warns
  end)
  return s
end

-- Expand every string in `config` (recursing into nested tables / `args` lists) against
-- the current context. Returns `expanded_config, unknown_names` (a list of the
-- unrecognised `${...}` tokens, in no particular order). Pure: it returns a fresh table
-- and never mutates the input.
function M.expand(config)
  local vars = M.context()
  local unknown = {}
  local function walk(v)
    local t = type(v)
    if t == "function" then
      -- A dynamic value: call it now, then expand whatever it produced (so a function
      -- may itself return a `${...}` string or a nested table). Fail loud on an error.
      local ok, res = pcall(v)
      if not ok then
        error("nxvim-dap: a configuration value function errored: " .. tostring(res), 0)
      end
      return walk(res)
    elseif t == "table" then
      local out = {}
      for k, val in pairs(v) do
        out[k] = walk(val)
      end
      return out
    elseif t == "string" then
      return expand_string(v, vars, unknown)
    end
    return v
  end
  local expanded = walk(config)
  local names = {}
  for name in pairs(unknown) do
    names[#names + 1] = name
  end
  return expanded, names
end

return M
