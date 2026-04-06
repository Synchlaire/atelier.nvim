-- Pure render: takes a State and returns lines + highlight ranges + a
-- row->target lookup table. No buffer access. Trivially testable.
--
---@class atelier.PickerRow
---@field kind 'header'|'theme'|'spacer'|'footer'
---@field spec_name string|nil
---@field theme string|nil
---@field rt atelier.ThemeRuntime|nil

---@class atelier.PickerView
---@field lines string[]
---@field highlights { line: integer, col_start: integer, col_end: integer, group: string }[]
---@field rows atelier.PickerRow[]   One entry per line; index matches lines[].

local Icons = require('atelier.ui.icons')
local Manager = require('atelier.manager')

local M = {}

local STATUS_GROUP = {
  installed  = 'AtelierStatusOk',
  missing    = 'AtelierMuted',
  installing = 'AtelierStatusBusy',
  updating   = 'AtelierStatusBusy',
  failed     = 'AtelierStatusErr',
  unknown    = 'AtelierMuted',
}

---@param state atelier.State
---@return atelier.PickerView
function M.render(state)
  local lines = {}
  local highlights = {}
  local rows = {}
  local icons = Icons.active

  local function push(line, row)
    lines[#lines + 1] = line
    rows[#rows + 1] = row
  end

  local function hl(group, line_idx, col_start, col_end)
    highlights[#highlights + 1] = {
      line = line_idx - 1, -- 0-indexed for nvim_buf_set_extmark
      col_start = col_start,
      col_end = col_end,
      group = group,
    }
  end

  -- Header
  push('  atelier', { kind = 'header' })
  hl('AtelierTitle', #lines, 2, 9)
  push('  ' .. #state.themes .. ' themes', { kind = 'header' })
  hl('AtelierMuted', #lines, 0, -1)
  push('', { kind = 'spacer' })

  for _, rt in ipairs(state.themes) do
    local variants = Manager.discover(state, rt)
    -- If no variants discovered (e.g. not yet installed), show the spec name
    -- itself as a single row so the user has something to act on.
    local theme_list = (#variants > 0) and variants or { rt.spec.name }

    for _, theme in ipairs(theme_list) do
      local is_current = (state.current.spec_name == rt.spec.name)
        and (state.current.theme == theme)
      local icon = is_current and icons.current or icons[rt.status] or '?'
      local prefix = '  ' .. icon .. ' '
      local line = prefix .. theme

      if rt.status == 'failed' and rt.error then
        line = line .. '  ' .. rt.error
      end

      push(line, { kind = 'theme', spec_name = rt.spec.name, theme = theme, rt = rt })

      local line_idx = #lines
      hl(STATUS_GROUP[rt.status] or 'AtelierMuted', line_idx, 2, 2 + #icon)
      hl(is_current and 'AtelierCurrent' or 'AtelierItem', line_idx, #prefix, #prefix + #theme)
      if rt.status == 'failed' and rt.error then
        hl('AtelierStatusErr', line_idx, #prefix + #theme + 2, -1)
      end
    end
  end

  push('', { kind = 'spacer' })
  push("  <CR> select   I install   U update   q quit", { kind = 'footer' })
  hl('AtelierMuted', #lines, 0, -1)

  return { lines = lines, highlights = highlights, rows = rows }
end

return M
