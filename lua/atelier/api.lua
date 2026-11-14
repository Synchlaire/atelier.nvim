-- The documented public surface. Anything not exported here is private.
-- The init.lua module re-exports all of these so users can call them as
-- `require('atelier').<fn>` instead of digging into submodules.
--
local M = {}

---@type atelier.State|nil
local state = nil

local function finish_preview(s)
  if not s.preview then return end
  local windows = package.loaded['atelier.ui.window']
  local window = windows and windows.get()
  if window and window.state == s then
    window:close()
  else
    s.preview:cleanup()
  end
end

---@param s atelier.State
function M._bind(s)
  if state then
    finish_preview(state)
    require('atelier.appearance').stop(state)
  end
  state = s
end

function M._state()
  return state
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
  finish_preview(s)
  return require('atelier.selection').apply(s, spec_name, theme)
end

---Apply and remember Light, Dark or Auto for the current theme.
function M.set_mode(mode)
  local s = require_state()
  finish_preview(s)
  if not s.current.spec_name then return false, 'no active Atelier theme' end
  return require('atelier.selection').apply(s, s.current.spec_name, s.current.choice or s.current.theme, {
    mode = mode, strict_mode = true, background = s.current.background,
  })
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
