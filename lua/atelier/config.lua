-- Config defaults + normalization. Runs once at setup(); all other modules
-- read the normalized form (atelier.Config) and never see the raw user input.
--
---@class atelier.ThemeSpec
---@field name string         Repo basename, used as the directory name and the user-visible label.
---@field url string|nil      Git URL, or nil for built-ins / already-installed colorschemes.
---@field source string       The original spec ('owner/repo', a name, or an absolute path).
---@field branch string|nil   Branch / tag / commit to check out.
---@field only string[]       Theme whitelist. Empty = allow all themes the colorscheme exposes.
---@field except string[]     Theme blacklist.
---@field before fun(name: string)|nil  Per-spec hook fired before :colorscheme.
---@field after  fun(name: string)|nil  Per-spec hook fired after :colorscheme.
---@field local_path string|nil         If the spec is an absolute path, the path itself; manager skips git for these.
---@field builtin boolean               True if this is a Neovim built-in colorscheme (no install needed).

---@class atelier.Config
---@field themes atelier.ThemeSpec[]
---@field install_on_setup boolean
---@field parallel integer
---@field preview_delay_ms integer
---@field persist boolean
---@field activity boolean
---@field data_dir string
---@field on_load fun(name: string)|nil

local M = {}

---@type atelier.Config
M.defaults = {
  themes = {},
  install_on_setup = false,
  parallel = 4,
  preview_delay_ms = 120,
  persist = true,
  activity = false,
  data_dir = '', -- resolved in normalize() so tests can stub vim.fn.stdpath
  on_load = nil,
}

-- Built-in colorschemes that ship with Neovim. We keep this list short and
-- conservative; anything not here is treated as a remote spec unless it
-- looks like an absolute path.
local BUILTINS = {
  default = true,
  habamax = true,
  industry = true,
  lunaperche = true,
  retrobox = true,
  slate = true,
  sorbet = true,
  vim = true,
  wildcharm = true,
  zaibatsu = true,
  -- Light side
  delek = true,
  morning = true,
  peachpuff = true,
  quiet = true,
  shine = true,
  zellner = true,
}

---@param s string
---@return boolean
local function is_absolute_path(s)
  return s:sub(1, 1) == '/' or s:sub(1, 2) == '~/'
end

---@param source string
---@return string
local function basename(source)
  return source:match('([^/]+)$') or source
end

---@param raw string|table
---@return atelier.ThemeSpec
local function normalize_one(raw)
  local source
  local extra = {}

  if type(raw) == 'string' then
    source = raw
  elseif type(raw) == 'table' then
    source = raw[1]
    if type(source) ~= 'string' then
      error('[atelier] theme spec table must have its source string as element [1]')
    end
    extra = raw
  else
    error('[atelier] theme spec must be a string or table, got ' .. type(raw))
  end

  local name = basename(source):gsub('%.git$', ''):gsub('%.nvim$', '')
  -- Keep the .nvim suffix in the *directory* name to avoid collisions, but
  -- the user-facing name is the stripped version. We restore the dir name
  -- when computing local paths in the manager.

  local spec = {
    name = name,
    source = source,
    branch = extra.branch,
    only = extra.only or {},
    except = extra.except or {},
    before = extra.before,
    after = extra.after,
    builtin = false,
    local_path = nil,
    url = nil,
  }

  if BUILTINS[source] then
    spec.builtin = true
  elseif is_absolute_path(source) then
    spec.local_path = source:gsub('^~', vim.env.HOME or '')
  elseif source:match('^[%w%-_%.]+/[%w%-_%.]+$') then
    spec.url = 'https://github.com/' .. source .. '.git'
  else
    -- Bare name with no slash and not a builtin: assume it's a colorscheme
    -- already on the runtimepath (installed by another plugin manager).
    spec.builtin = true
  end

  return spec
end

---Normalize the user's setup() table into a frozen Config.
---@param user table|nil
---@return atelier.Config
function M.normalize(user)
  user = user or {}

  -- Allow `setup({ 'foo/bar', 'baz/qux' })` shorthand: array-style at the
  -- top level is treated as the themes list.
  local themes_raw
  if user.themes then
    themes_raw = user.themes
  elseif #user > 0 then
    themes_raw = user
  else
    themes_raw = {}
  end

  local themes = {}
  for i, raw in ipairs(themes_raw) do
    local ok, spec = pcall(normalize_one, raw)
    if ok then
      themes[#themes + 1] = spec
    else
      vim.schedule(function()
        vim.notify(('[atelier] theme #%d: %s'):format(i, spec), vim.log.levels.ERROR)
      end)
    end
  end

  local data_dir = user.data_dir
  if not data_dir or data_dir == '' then
    data_dir = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'atelier')
  end

  ---@type atelier.Config
  local cfg = {
    themes = themes,
    install_on_setup = user.install_on_setup == true,
    parallel = math.max(1, tonumber(user.parallel) or M.defaults.parallel),
    preview_delay_ms = math.max(0, tonumber(user.preview_delay_ms) or M.defaults.preview_delay_ms),
    persist = user.persist ~= false,
    activity = user.activity == true,
    data_dir = data_dir,
    on_load = user.on_load,
  }

  return cfg
end

return M
