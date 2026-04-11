-- Single mutable State table threaded explicitly through the rest of atelier.
-- Created once in setup(); no module-level globals.
--
---@alias atelier.Status 'unknown'|'missing'|'installed'|'installing'|'updating'|'failed'

---@class atelier.ThemeRuntime
---@field spec atelier.ThemeSpec
---@field status atelier.Status
---@field error string|nil       First line of stderr if status == 'failed'.
---@field progress integer       0..100, only meaningful while installing/updating.
---@field themes string[]|nil    Cached list of theme names (from colors/*.lua|vim) once known.
---@field expanded boolean       Picker UI state: is this spec's variant list visible.

---@class atelier.Current
---@field spec_name string|nil   Name of the spec that owns the active theme.
---@field theme string|nil       The actual `:colorscheme` value.
---@field background 'dark'|'light'|nil  The `vim.o.background` value at the time the theme was committed. nil if the user never declared one for this variant.

---@class atelier.UiState
---@field filter string                  Current filter query (lowercased). Empty = no filter.
---@field mode 'normal'|'filter'         Picker input mode.
---@field collapsed_default boolean      What `expanded` defaults to when a new spec runtime is created.

---@class atelier.State
---@field config atelier.Config
---@field bus atelier.Bus
---@field themes atelier.ThemeRuntime[]      Order matches config.themes for stable picker order.
---@field by_name table<string, atelier.ThemeRuntime>
---@field current atelier.Current
---@field last_good atelier.Current          Persisted snapshot for restore-on-cancel and crash recovery.
---@field ui atelier.UiState                  Picker UI state. Reset on each picker open.

local Bus = require('atelier.events')

local M = {}

---@param config atelier.Config
---@return atelier.State
function M.new(config)
  local state = {
    config = config,
    bus = Bus.new(),
    themes = {},
    by_name = {},
    current = { spec_name = nil, theme = nil, background = nil },
    last_good = { spec_name = nil, theme = nil, background = nil },
    ui = {
      filter = '',
      mode = 'normal',
      collapsed_default = true, -- folded by default; l to unfold, h to fold
    },
  }

  for _, spec in ipairs(config.themes) do
    ---@type atelier.ThemeRuntime
    local rt = {
      spec = spec,
      status = 'unknown',
      error = nil,
      progress = 0,
      themes = nil,
      expanded = not state.ui.collapsed_default,
    }
    state.themes[#state.themes + 1] = rt
    state.by_name[spec.name] = rt
  end

  return state
end

---Reset the UI substate (filter, mode) without touching install state or
---fold state. Called when the picker opens so a stale `mode = 'filter'`
---can't survive between sessions.
---@param state atelier.State
function M.reset_ui(state)
  state.ui.filter = ''
  state.ui.mode = 'normal'
end

---Find a runtime entry by user-facing name.
---@param state atelier.State
---@param name string
---@return atelier.ThemeRuntime|nil
function M.get(state, name)
  return state.by_name[name]
end

return M
