-- Shared selection transaction for startup, API, preview and desktop events.
local Loader = require('atelier.loader')
local Manager = require('atelier.manager')
local M = {}

local function allowed(spec, theme)
  if spec.only and #spec.only > 0 and not vim.tbl_contains(spec.only, theme) then return false end
  return not (spec.except and vim.tbl_contains(spec.except, theme))
end

function M.variant_for(spec, mode, preferred)
  if preferred and allowed(spec, preferred) and Loader.declared_background(spec, preferred) == mode then
    return preferred
  end
  -- Stable order matters when more than one variant declares the same mode.
  local names = vim.tbl_keys(spec.backgrounds or {})
  table.sort(names)
  for _, name in ipairs(names) do
    if allowed(spec, name) and spec.backgrounds[name] == mode then return name end
  end
  if spec.background == mode and allowed(spec, spec.name) then return spec.name end
end

function M.supports_auto(spec)
  return spec.auto == true
    or (M.variant_for(spec, 'dark') ~= nil and M.variant_for(spec, 'light') ~= nil)
end

local function resolve(state, rt, theme, mode, fallback)
  local spec = rt.spec
  if not allowed(spec, theme) then return nil, 'variant excluded by theme configuration: ' .. theme end
  local effective = mode
  if mode == 'auto' then
    effective = M.supports_auto(spec) and state.desktop and state.desktop.background or nil
    effective = effective or fallback or Loader.declared_background(spec, theme) or vim.o.background
  end
  if spec.auto then return theme, effective end
  local declared = Loader.declared_background(spec, theme)
  local can_pair = mode ~= 'auto' or M.supports_auto(spec)
  local variant = can_pair and (declared or theme == spec.name) and M.variant_for(spec, effective, theme) or nil
  if variant then return variant, effective end
  if declared then
    if mode ~= 'auto' and declared ~= effective then
      return nil, spec.name .. ' does not declare a ' .. effective .. ' variant'
    end
    return theme, declared
  end
  -- Unknown capabilities never follow the host. Manual background changes
  -- remain possible because the user explicitly requested them.
  if mode == 'auto' and not M.supports_auto(spec) then
    return theme, fallback or vim.o.background
  end
  return theme, effective
end

---Restore an exact visual snapshot, not a fresh resolution of Auto.
function M.restore(state, snapshot)
  local theme = snapshot.theme or 'default'
  local previous = state.current and state.by_name[state.current.spec_name]
  if previous and state.current.theme == theme then
    Manager.activate(state, previous)
    return Loader.load(previous.spec, theme, nil, snapshot.background)
  end
  vim.o.background = snapshot.background
  return pcall(vim.cmd.colorscheme, theme)
end

---@param options table|nil mode, background, strict_mode (mode changes only), hooks (default true)
---@return boolean, atelier.Current|string
function M.load(state, spec_name, theme, options)
  options = options or {}
  local rt = state.by_name[spec_name]
  if not rt then return false, 'unknown theme: ' .. tostring(spec_name) end
  local mode = options.mode or state.current.mode or state.config.mode or 'auto'
  if mode ~= 'auto' and mode ~= 'dark' and mode ~= 'light' then
    return false, "mode must be 'auto', 'dark' or 'light'"
  end
  local choice = theme or rt.spec.name
  local declared = Loader.declared_background(rt.spec, choice)
  -- Picking a variant is an explicit choice, not a request to find some
  -- other variant matching yesterday's mode. Mode controls are strict.
  if not options.strict_mode and mode ~= 'auto' and declared and not rt.spec.auto then
    mode = declared
  end
  local target, bg = resolve(state, rt, choice, mode, options.background)
  if not target then return false, bg end
  local active, activation_err = Manager.activate(state, rt)
  if not active then return false, activation_err end
  local snapshot = { theme = vim.g.colors_name, background = vim.o.background }
  local hook = options.hooks ~= false and state.config.on_load or nil
  local ok, err = Loader.load(rt.spec, target, hook, bg)
  if not ok then
    M.restore(state, snapshot)
    return false, err
  end
  return true, { spec_name = spec_name, choice = choice, theme = target, background = vim.o.background, mode = mode }
end

function M.save(state, current)
  if not state.config.persist then return true end
  local saved, err = require('atelier.persist').write(state.config.data_dir, current)
  if not saved then state.ui.message = 'Applied, but could not save selection: ' .. tostring(err) end
  return saved, err
end

---A background-only cache refresh must not replace another session's
---different explicit selection. No write when the saved preference moved on.
function M.cache(state, current)
  if not state.config.persist then return true end
  local saved = require('atelier.persist').read(state.config.data_dir)
  local mode = saved.mode
  local rt = state.by_name[saved.spec_name]
  if not mode and rt and Loader.declared_background(rt.spec, saved.theme) == saved.background then
    mode = state.config.mode
  end
  if mode ~= 'auto' or saved.spec_name ~= current.spec_name
    or (saved.choice or saved.theme) ~= current.choice then return true end
  return M.save(state, current)
end

function M.commit(state, current, save)
  state.current = vim.deepcopy(current)
  state.last_good = vim.deepcopy(current)
  state.ui.previewed = nil
  local saved, err = true, nil
  if save ~= false then saved, err = M.save(state, current) end
  require('atelier.appearance').reconcile(state)
  state.bus:emit('state_changed')
  return saved, err
end

function M.apply(state, spec_name, theme, options)
  local ok, result = M.load(state, spec_name, theme, options)
  if not ok then return false, result end
  M.commit(state, result)
  return true
end

return M
