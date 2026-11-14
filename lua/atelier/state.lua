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
---@field activated boolean|nil   Provider was added to runtimepath on demand.
---@field expanded boolean       Picker UI state: is this spec's variant list visible.

---@class atelier.Current
---@field spec_name string|nil   Name of the spec that owns the active theme.
---@field theme string|nil       The effective `:colorscheme` value.
---@field choice string|nil      User-selected anchor, preserved across automatic variant changes.
---@field background 'dark'|'light'|nil Effective background, also used as the offline Auto fallback.
---@field mode 'auto'|'dark'|'light'|nil User preference, separate from the resolved background.

---@class atelier.UiState
---@field filter string                  Current filter query (lowercased). Empty = no filter.
---@field mode 'normal'|'filter'         Picker input mode.
---@field collapsed_default boolean      What `expanded` defaults to when a new spec runtime is created.
---@field previewed atelier.Current|nil  Theme currently previewed but not applied.
---@field help boolean                   Whether the workshop help card is open.
---@field message string|nil             Short-lived operation/result message.

---@class atelier.Operation
---@field kind 'install'|'update'
---@field completed integer
---@field total integer
---@field failed integer

---@class atelier.State
---@field config atelier.Config
---@field bus atelier.Bus
---@field themes atelier.ThemeRuntime[]      Order matches config.themes for stable picker order.
---@field by_name table<string, atelier.ThemeRuntime>
---@field current atelier.Current
---@field last_good atelier.Current          Persisted snapshot for restore-on-cancel and crash recovery.
---@field ui atelier.UiState                  Picker UI state. Reset on each picker open.
---@field desktop table                Appearance subscription and latest host preference.
---@field preview atelier.Preview|nil   Active transaction; host changes are deferred while open.
---@field operation atelier.Operation|nil     Aggregate install/update progress.

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
    current = { spec_name = nil, theme = nil, background = nil, mode = config.mode or 'auto' },
    last_good = { spec_name = nil, theme = nil, background = nil, mode = config.mode or 'auto' },
    desktop = { background = nil },
    operation = nil,
    ui = {
      filter = '',
      mode = 'normal',
      collapsed_default = true, -- folded by default; l to unfold, h to fold
      previewed = nil,
      help = false,
      message = nil,
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
  state.ui.previewed = nil
  state.ui.help = false
  state.ui.message = nil
end

---Find a runtime entry by user-facing name.
---@param state atelier.State
---@param name string
---@return atelier.ThemeRuntime|nil
function M.get(state, name)
  return state.by_name[name]
end

return M
