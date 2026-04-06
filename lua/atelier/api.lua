-- The documented public surface. Anything not exported here is private.
-- The init.lua module re-exports all of these so users can call them as
-- `require('atelier').<fn>` instead of digging into submodules.
--
local M = {}

---@type atelier.State|nil
local state = nil

---@param s atelier.State
function M._bind(s)
  state = s
end

---@return atelier.State
local function require_state()
  if not state then
    error('[atelier] not initialized; call require("atelier").setup({...}) first')
  end
  return state
end

---Open the picker.
function M.pick()
  require('atelier.ui').open(require_state())
end

---Load a theme by spec name (and optional variant). Updates current and
---persists if config.persist is on.
---@param spec_name string
---@param theme string|nil
function M.load(spec_name, theme)
  local s = require_state()
  local rt = s.by_name[spec_name]
  if not rt then
    return false, 'unknown theme: ' .. spec_name
  end
  local Loader = require('atelier.loader')
  local target = theme or rt.spec.name
  local ok, err = Loader.load(rt.spec, target, s.config.on_load)
  if ok then
    -- Snapshot vim.o.background AFTER load: this captures both the
    -- declared background (loader sets it) and any prior `B` toggle the
    -- user committed via `<CR>`, while still recording nil for specs
    -- that don't care.
    local bg = nil
    local declared = Loader.declared_background(rt.spec, target)
    if declared then bg = vim.o.background end
    s.current = { spec_name = spec_name, theme = target, background = bg }
    s.last_good = { spec_name = spec_name, theme = target, background = bg }
    if s.config.persist then
      require('atelier.persist').write(s.config.data_dir, s.current)
    end
    s.bus:emit('state_changed')
  end
  return ok, err
end

---@return atelier.Current
function M.current()
  return require_state().current
end

---List all themes (one entry per spec). For variant-level inspection use
---the picker or the runtime entry's `themes` field after install.
---@return atelier.ThemeRuntime[]
function M.list()
  return require_state().themes
end

function M.install()
  require('atelier.manager').install_missing(require_state())
end

function M.update()
  require('atelier.manager').update_all(require_state())
end

function M.clean()
  require('atelier.manager').clean(require_state())
end

---@param event string
---@param cb fun(...)
function M.on(event, cb)
  require_state().bus:on(event, cb)
end

---@param event string
---@param cb fun(...)
function M.off(event, cb)
  require_state().bus:off(event, cb)
end

return M
