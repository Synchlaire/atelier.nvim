-- Pure render: takes a State and returns lines + highlight ranges + a
-- row->target lookup table. No buffer access. Trivially testable.
--
-- Layout (top → bottom):
--   atelier title
--   filter input row (only when state.ui.mode == 'filter' or filter ~= '')
--   spec headers (▾/▸ + name + status badge + variant count)
--     variant rows under each expanded spec
--   footer with key hints
--
---@class atelier.PickerRow
---@field kind 'header'|'filter'|'spec_header'|'theme'|'spacer'|'footer'
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

local STATUS_LABEL = {
  installed  = 'installed',
  missing    = 'missing',
  installing = 'installing',
  updating   = 'updating',
  failed     = 'failed',
  unknown    = '',
}

---@param needle string lowercased
---@param haystack string
---@return boolean
local function matches(needle, haystack)
  if needle == '' then return true end
  return haystack:lower():find(needle, 1, true) ~= nil
end

---@param state atelier.State
---@return atelier.PickerView
function M.render(state)
  local lines = {}
  local highlights = {}
  local rows = {}
  local icons = Icons.active
  local filter = state.ui.filter

  local function push(line, row)
    lines[#lines + 1] = line
    rows[#rows + 1] = row
  end

  local function hl(group, line_idx, col_start, col_end)
    highlights[#highlights + 1] = {
      line = line_idx - 1,
      col_start = col_start,
      col_end = col_end,
      group = group,
    }
  end

  -- ── header ────────────────────────────────────────────────────────────
  push('  atelier', { kind = 'header' })
  hl('AtelierTitle', #lines, 2, 9)

  local total_variants = 0
  local visible_variants = 0
  local spec_views = {} -- precomputed: { rt, variants_visible, force_expand }

  for _, rt in ipairs(state.themes) do
    local variants = Manager.discover(state, rt)
    local theme_list = (#variants > 0) and variants or { rt.spec.name }
    total_variants = total_variants + #theme_list

    local matching_variants = {}
    if filter == '' then
      matching_variants = theme_list
    else
      local spec_matches = matches(filter, rt.spec.name)
      for _, t in ipairs(theme_list) do
        if spec_matches or matches(filter, t) then
          matching_variants[#matching_variants + 1] = t
        end
      end
    end

    visible_variants = visible_variants + #matching_variants
    spec_views[#spec_views + 1] = {
      rt = rt,
      variants = matching_variants,
      -- When the user is filtering, force open any spec that has matches.
      force_expand = filter ~= '' and #matching_variants > 0,
      -- Hide specs that have zero matching variants when filtering.
      visible = filter == '' or #matching_variants > 0,
    }
  end

  if filter ~= '' then
    push(('  %d/%d themes  ·  filter: %s'):format(visible_variants, total_variants, filter),
      { kind = 'header' })
  else
    push(('  %d themes'):format(total_variants), { kind = 'header' })
  end
  hl('AtelierMuted', #lines, 0, -1)

  -- ── filter input row ──────────────────────────────────────────────────
  if state.ui.mode == 'filter' then
    push('  /' .. filter .. '█', { kind = 'filter' })
    hl('AtelierKey', #lines, 2, 3)
    hl('AtelierItem', #lines, 3, -1)
  end

  push('', { kind = 'spacer' })

  -- ── spec groups ───────────────────────────────────────────────────────
  for _, sv in ipairs(spec_views) do
    if not sv.visible then goto continue end

    local rt = sv.rt
    local expanded = rt.expanded or sv.force_expand
    local fold_icon = expanded and icons.expanded or icons.collapsed
    local status_label = STATUS_LABEL[rt.status] or ''
    local count = #sv.variants
    local count_str = filter ~= '' and ('(%d/%d)'):format(count, #(rt.themes or { rt.spec.name }))
      or ('(%d)'):format(count)

    -- Header line: "▾ wing                            installed (3)"
    local header_line = ('  %s %s'):format(fold_icon, rt.spec.name)
    -- Pad to a consistent column for the status badge.
    local pad_to = 36
    if #header_line < pad_to then
      header_line = header_line .. string.rep(' ', pad_to - #header_line)
    else
      header_line = header_line .. ' '
    end
    header_line = header_line .. status_label .. ' ' .. count_str
    if rt.status == 'failed' and rt.error then
      header_line = header_line .. '  ' .. rt.error
    end

    push(header_line, { kind = 'spec_header', spec_name = rt.spec.name, rt = rt })

    local line_idx = #lines
    hl('AtelierKey', line_idx, 2, 2 + #fold_icon)
    hl('AtelierItem', line_idx, 2 + #fold_icon + 1, 2 + #fold_icon + 1 + #rt.spec.name)
    if status_label ~= '' then
      local badge_start = math.max(pad_to, 2 + #fold_icon + 1 + #rt.spec.name + 1)
      hl(STATUS_GROUP[rt.status] or 'AtelierMuted', line_idx, badge_start, badge_start + #status_label)
    end
    if rt.status == 'failed' and rt.error then
      hl('AtelierStatusErr', line_idx, #header_line - #rt.error, -1)
    end

    -- Variant rows (only if expanded)
    if expanded then
      for _, theme in ipairs(sv.variants) do
        local is_current = (state.current.spec_name == rt.spec.name)
          and (state.current.theme == theme)
        local marker = is_current and icons.current or ' '
        local prefix = '      ' .. marker .. ' '
        local line = prefix .. theme

        push(line, { kind = 'theme', spec_name = rt.spec.name, theme = theme, rt = rt })

        local idx = #lines
        if is_current then
          hl('AtelierCurrent', idx, 6, 6 + #marker)
          hl('AtelierCurrent', idx, #prefix, #prefix + #theme)
        else
          hl('AtelierItem', idx, #prefix, #prefix + #theme)
        end
      end
    end

    ::continue::
  end

  push('', { kind = 'spacer' })

  -- ── footer ────────────────────────────────────────────────────────────
  if state.ui.mode == 'filter' then
    push("  type to filter   <CR> apply   <Esc> cancel", { kind = 'footer' })
  else
    push("  <CR> select  <Tab> fold  / search  I install  U update  q quit",
      { kind = 'footer' })
  end
  hl('AtelierMuted', #lines, 0, -1)

  return { lines = lines, highlights = highlights, rows = rows }
end

---Toggle the fold state of one spec.
---@param state atelier.State
---@param spec_name string
function M.toggle_fold(state, spec_name)
  local rt = state.by_name[spec_name]
  if rt then
    rt.expanded = not rt.expanded
    state.bus:emit('state_changed')
  end
end

---@param state atelier.State
---@param expanded boolean
function M.set_all_folds(state, expanded)
  for _, rt in ipairs(state.themes) do
    rt.expanded = expanded
  end
  state.bus:emit('state_changed')
end

return M
