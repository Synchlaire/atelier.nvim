-- Pure render: takes a State (+ window inner width) and returns lines,
-- highlight ranges, and a row→target lookup table. No buffer access.
-- Trivially testable.
--
-- Wing OS layout (top → bottom):
--   ATELIER · N themes                               (header)
--   ─────────────────────────────────────            (rule, full width)
--   /needle█                                         (filter slot; reserved)
--   WING ─────────────────────────────── installing  (spec group header + optional status)
--   • wing-dark                          ·  dark     (variant rows)
--     wing-light                         · light
--   KANAGAWA ────────────────────────────            (next group)
--     kanagawa-wave                      ·  dark
--   ─────────────────────────────────────            (footer rule)
--   <CR> select · / filter · B bg · I U C · q        (footer hints)
--
---@class atelier.PickerRow
---@field kind 'header'|'rule'|'filter'|'spec_header'|'theme'|'error'|'footer'|'spacer'
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
  missing    = 'AtelierStatusMissing',
  installing = 'AtelierStatusBusy',
  updating   = 'AtelierStatusBusy',
  failed     = 'AtelierStatusErr',
  unknown    = 'AtelierSubtle',
}

local STATUS_LABEL = {
  installed  = '',        -- normal case: no badge, rule extends to edge
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

---Given a variant name, return the declared background mode (if any).
---Checks `spec.backgrounds[variant]` first, then falls back to
---`spec.background`. Returns nil when the user hasn't declared one.
---@param spec atelier.ThemeSpec
---@param variant string
---@return 'dark'|'light'|nil
function M.background_of(spec, variant)
  if spec.backgrounds then
    local b = spec.backgrounds[variant]
    if b == 'dark' or b == 'light' then return b end
  end
  if spec.background == 'dark' or spec.background == 'light' then
    return spec.background
  end
  return nil
end

---@param state atelier.State
---@param width integer  Window inner width (columns available for content).
---@return atelier.PickerView
function M.render(state, width)
  local lines = {}
  local highlights = {}
  local rows = {}
  local icons = Icons.active
  local filter = state.ui.filter
  width = width or 72

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

  local function rule_line()
    -- Full-width rule with 2-col left/right margin.
    return '  ' .. string.rep(icons.divider, math.max(0, width - 4))
  end

  -- ── header ────────────────────────────────────────────────────────────
  -- Pre-compute visible/total counts so the header line is accurate.
  local total_variants = 0
  local visible_variants = 0
  local spec_views = {}

  for _, rt in ipairs(state.themes) do
    local variants = Manager.discover(state, rt)
    local theme_list = (#variants > 0) and variants or { rt.spec.name }
    total_variants = total_variants + #theme_list

    local matching = {}
    if filter == '' then
      matching = theme_list
    else
      local spec_matches = matches(filter, rt.spec.name)
      for _, t in ipairs(theme_list) do
        if spec_matches or matches(filter, t) then
          matching[#matching + 1] = t
        end
      end
    end

    visible_variants = visible_variants + #matching
    spec_views[#spec_views + 1] = {
      rt = rt,
      variants = matching,
      visible = filter == '' or #matching > 0,
    }
  end

  -- Line 1: ATELIER · N themes
  local title = 'ATELIER'
  local count_text
  if filter ~= '' then
    count_text = (' %s %d/%d themes'):format(icons.sep, visible_variants, total_variants)
  else
    count_text = (' %s %d themes'):format(icons.sep, total_variants)
  end
  push('  ' .. title .. count_text, { kind = 'header' })
  hl('AtelierTitle', #lines, 2, 2 + #title)
  hl('AtelierSubtle', #lines, 2 + #title, -1)

  -- Line 2: top rule
  push(rule_line(), { kind = 'rule' })
  hl('AtelierDivider', #lines, 2, -1)

  -- Line 3: reserved filter slot (always present, empty when not filtering).
  -- Reserving the slot prevents vertical reflow when toggling filter mode.
  if state.ui.mode == 'filter' or filter ~= '' then
    local prompt = '  /'
    local needle = filter
    local cursor = state.ui.mode == 'filter' and '█' or ''
    push(prompt .. needle .. cursor, { kind = 'filter' })
    hl('AtelierFilterPrompt', #lines, 2, 3)
    if #needle > 0 then
      hl('AtelierTheme', #lines, 3, 3 + #needle)
    end
    if cursor ~= '' then
      hl('AtelierFilterCursor', #lines, 3 + #needle, -1)
    end
  else
    push('', { kind = 'spacer' })
  end

  -- ── spec groups ───────────────────────────────────────────────────────
  for _, sv in ipairs(spec_views) do
    if sv.visible then
      local rt = sv.rt
      local expanded = rt.expanded
      if expanded == nil then expanded = true end
      -- Force expand while filtering (so matches are visible).
      if filter ~= '' and #sv.variants > 0 then expanded = true end

      -- Spec header: "  WING ─────────────────────  installing"
      local name_upper = rt.spec.name:upper()
      local status_label = STATUS_LABEL[rt.status] or ''
      local hidden_tag = ''
      if not expanded then
        local count = #sv.variants
        hidden_tag = ('(%d hidden)'):format(count)
      end

      local label_part = '  ' .. name_upper .. ' '
      local right_part
      if status_label ~= '' and hidden_tag ~= '' then
        right_part = ' ' .. hidden_tag .. '  ' .. status_label
      elseif status_label ~= '' then
        right_part = ' ' .. status_label
      elseif hidden_tag ~= '' then
        right_part = ' ' .. hidden_tag
      else
        right_part = ''
      end

      -- Fill rule between label and right-side annotation.
      local fill_cols = width - 2 - #name_upper - 1 - #right_part - 2
      if fill_cols < 1 then fill_cols = 1 end
      local fill = string.rep(icons.divider, fill_cols)
      local header_line = label_part .. fill .. right_part

      push(header_line, { kind = 'spec_header', spec_name = rt.spec.name, rt = rt })
      local line_idx = #lines

      hl('AtelierSpecHeader', line_idx, 2, 2 + #name_upper)
      local fill_start = 2 + #name_upper + 1
      hl('AtelierDivider', line_idx, fill_start, fill_start + #fill)
      if right_part ~= '' then
        local right_start = fill_start + #fill
        if hidden_tag ~= '' then
          local hidden_pos = header_line:find(hidden_tag, right_start, true)
          if hidden_pos then
            hl('AtelierSubtle', line_idx, hidden_pos - 1, hidden_pos - 1 + #hidden_tag)
          end
        end
        if status_label ~= '' then
          local badge_pos = header_line:find(status_label, right_start, true)
          if badge_pos then
            hl(STATUS_GROUP[rt.status] or 'AtelierSubtle',
               line_idx, badge_pos - 1, badge_pos - 1 + #status_label)
          end
        end
      end

      -- Error line: indented, below the header, only when failed.
      if rt.status == 'failed' and rt.error then
        push('    ' .. rt.error, { kind = 'error', spec_name = rt.spec.name, rt = rt })
        hl('AtelierStatusErr', #lines, 4, -1)
      end

      -- Variant rows (when expanded).
      if expanded then
        local dw = vim.fn.strdisplaywidth
        for _, theme in ipairs(sv.variants) do
          local is_current = (state.current.spec_name == rt.spec.name)
            and (state.current.theme == theme)
          local marker = is_current and icons.current or ' '
          local left = '  ' .. marker .. ' ' .. theme
          local bg = M.background_of(rt.spec, theme)
          local right = ''
          if bg == 'dark' then
            right = icons.sep .. '  dark'
          elseif bg == 'light' then
            right = icons.sep .. ' light'
          end

          -- Right-align by DISPLAY width (not byte length): multi-byte
          -- glyphs like `•` would otherwise push the suffix left by 2
          -- cells on the current-theme row.
          local pad_cols = width - 2 - dw(left) - dw(right)
          if pad_cols < 1 then pad_cols = 1 end
          local line = left .. string.rep(' ', pad_cols) .. right

          push(line, { kind = 'theme', spec_name = rt.spec.name, theme = theme, rt = rt })
          local idx = #lines

          -- Marker highlight (current = green, always visible). Uses BYTE
          -- offsets since extmarks are byte-based.
          hl('AtelierCurrent', idx, 2, 2 + #marker)
          local name_start = 2 + #marker + 1
          local name_group = is_current and 'AtelierCurrent' or 'AtelierTheme'
          hl(name_group, idx, name_start, name_start + #theme)
          if right ~= '' then
            local suffix_start = #line - #right
            hl('AtelierThemeBg', idx, suffix_start, -1)
          end
        end
      end
    end
  end

  -- ── footer ────────────────────────────────────────────────────────────
  push(rule_line(), { kind = 'rule' })
  hl('AtelierDivider', #lines, 2, -1)

  local footer_line, keycaps
  if state.ui.mode == 'filter' then
    footer_line = '  type to filter ' .. icons.sep .. ' <CR> apply ' .. icons.sep .. ' <Esc> cancel'
    keycaps = { '<CR>', '<Esc>' }
  else
    footer_line = '  <CR> select ' .. icons.sep .. ' / filter ' .. icons.sep
      .. ' B bg ' .. icons.sep .. ' I U C ' .. icons.sep .. ' q'
    keycaps = { '<CR>', '/', 'B', 'I', 'U', 'C', 'q' }
  end
  push(footer_line, { kind = 'footer' })
  local footer_idx = #lines
  hl('AtelierSubtle', footer_idx, 0, -1)
  -- Overlay keycap highlights on the subtle base.
  local cursor_col = 2
  for _, cap in ipairs(keycaps) do
    local pos = footer_line:find(cap, cursor_col + 1, true)
    if pos then
      hl('AtelierKey', footer_idx, pos - 1, pos - 1 + #cap)
      cursor_col = pos - 1 + #cap
    end
  end

  return { lines = lines, highlights = highlights, rows = rows }
end

---Toggle the fold state of one spec.
---@param state atelier.State
---@param spec_name string
function M.toggle_fold(state, spec_name)
  local rt = state.by_name[spec_name]
  if rt then
    if rt.expanded == nil then rt.expanded = true end
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

---Find a variant of `spec` that the user has explicitly declared as having
---background `mode`. Returns the variant name or nil. Used by the `B`
---toggle to switch to a paired light/dark variant when one is available.
---@param spec atelier.ThemeSpec
---@param mode 'dark'|'light'
---@return string|nil
function M.find_variant_for(spec, mode)
  if spec.backgrounds then
    for variant, m in pairs(spec.backgrounds) do
      if m == mode then return variant end
    end
  end
  if spec.background == mode then
    return spec.name
  end
  return nil
end

return M
