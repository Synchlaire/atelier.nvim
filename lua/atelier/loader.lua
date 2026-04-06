-- Theme switching with lifecycle hooks. Pure orchestration: it does NOT
-- touch state mutation or persistence (those happen in the api/manager
-- callers). It only runs before/colorscheme/after/on_load and reports
-- success.
--
local M = {}

---@param spec atelier.ThemeSpec
---@param theme string|nil  Specific theme name to load (e.g. 'tokyonight-night'). nil = use spec.name.
---@param on_load fun(name: string)|nil  Global on_load hook from config.
---@return boolean ok, string? err
function M.load(spec, theme, on_load)
  local target = theme or spec.name

  if spec.before then
    local ok, err = pcall(spec.before, target)
    if not ok then
      return false, 'before hook failed: ' .. tostring(err)
    end
  end

  local ok, err = pcall(vim.cmd.colorscheme, target)
  if not ok then
    return false, tostring(err)
  end

  if spec.after then
    local ok2, err2 = pcall(spec.after, target)
    if not ok2 then
      vim.schedule(function()
        vim.notify('[atelier] after hook failed: ' .. tostring(err2), vim.log.levels.WARN)
      end)
    end
  end

  if on_load then
    local ok3, err3 = pcall(on_load, target)
    if not ok3 then
      vim.schedule(function()
        vim.notify('[atelier] on_load failed: ' .. tostring(err3), vim.log.levels.WARN)
      end)
    end
  end

  return true
end

---Discover the theme variants a colorscheme exposes by scanning its colors/
---directory. Cached on the runtime entry by the caller.
---@param plugin_dir string|nil  Absolute path to the plugin root, or nil to scan rtp.
---@return string[]
function M.discover_themes(plugin_dir)
  local results = {}
  local seen = {}

  local function add(name)
    if not seen[name] then
      seen[name] = true
      results[#results + 1] = name
    end
  end

  if plugin_dir then
    local colors = vim.fs.joinpath(plugin_dir, 'colors')
    local handle = (vim.uv or vim.loop).fs_scandir(colors)
    if handle then
      while true do
        local name, _ = (vim.uv or vim.loop).fs_scandir_next(handle)
        if not name then break end
        local stripped = name:match('^(.+)%.lua$') or name:match('^(.+)%.vim$')
        if stripped then add(stripped) end
      end
    end
  else
    -- Built-in or rtp scan: use Neovim's own search.
    for _, file in ipairs(vim.api.nvim_get_runtime_file('colors/*.lua', true)) do
      local n = file:match('([^/]+)%.lua$')
      if n then add(n) end
    end
    for _, file in ipairs(vim.api.nvim_get_runtime_file('colors/*.vim', true)) do
      local n = file:match('([^/]+)%.vim$')
      if n then add(n) end
    end
  end

  table.sort(results)
  return results
end

---Apply only/except filters to a list of theme names.
---@param themes string[]
---@param spec atelier.ThemeSpec
---@return string[]
function M.filter(themes, spec)
  if #spec.only == 0 and #spec.except == 0 then return themes end
  local only_set = {}
  for _, n in ipairs(spec.only) do only_set[n] = true end
  local except_set = {}
  for _, n in ipairs(spec.except) do except_set[n] = true end

  local out = {}
  for _, n in ipairs(themes) do
    local pass = true
    if next(only_set) and not only_set[n] then pass = false end
    if except_set[n] then pass = false end
    if pass then out[#out + 1] = n end
  end
  return out
end

return M
