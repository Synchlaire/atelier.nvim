-- Pure render: State (+ width, height, hovered row) → lines, highlights,
-- and a row-lookup table. No buffer access. Trivially testable.
--
-- Single-column flat list. Specs are folded by default; `l` unfolds and
-- `h` folds. Navigation uses `j`/`k` to move through selectable rows.
--
---@class atelier.PickerRow
---@field kind 'header'|'rule'|'filter'|'spec_header'|'theme'|'error'|'footer'|'info'|'spacer'
---@field spec_name string|nil
---@field theme string|nil
---@field rt atelier.ThemeRuntime|nil

---@class atelier.PickerView
---@field lines string[]
---@field highlights { line: integer, col_start: integer, col_end: integer, group: string }[]
---@field rows atelier.PickerRow[]

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
  installed  = '',
  missing    = 'missing',
  installing = 'installing',
  updating   = 'updating',
  failed     = 'failed',
  unknown    = '',
}

local CHROME_ROWS = 7 -- header + rule + filter + rule + info + rule + footer

---@param needle string lowercased
---@param haystack string
---@return boolean
local function matches(needle, haystack)
  if needle == '' then return true end
  return haystack:lower():find(needle, 1, true) ~= nil
end

---Given a variant name, return the declared background mode (if any).
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

local function pad_to_width(s, w)
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then return s end
  return s .. string.rep(' ', w - dw)
end

---@param state atelier.State
---@param width integer
---@param height integer
---@param hovered atelier.PickerRow|nil
---@return atelier.PickerView
function M.render(state, width, height, hovered)
  local lines = {}
  local highlights = {}
  local rows = {}
  local icons = Icons.active
  local filter = state.ui.filter
  width = width or 72
  height = height or 28

  local body_w = width - 4 -- 2-char left margin, 2-char right margin

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
    return '  ' .. string.rep(icons.divider, math.max(0, width - 4))
  end

  -- ── pre-compute spec_views (filter logic) ────────────────────────────
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

  -- ── header ────────────────────────────────────────────────────────────
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

  push(rule_line(), { kind = 'rule' })
  hl('AtelierDivider', #lines, 2, -1)

  -- Reserved filter slot.
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

  -- ── body ─────────────────────────────────────────────────────────────
  local body_budget = height - CHROME_ROWS
  if body_budget < 4 then body_budget = 4 end
  local body_first_line = #lines + 1

  for _, sv in ipairs(spec_views) do
    if sv.visible then
      local rt = sv.rt
      local expanded = rt.expanded
      if expanded == nil then expanded = false end
      if filter ~= '' and #sv.variants > 0 then expanded = true end

      -- Spec header.
      local name_upper = rt.spec.name:upper()
      local status_label = STATUS_LABEL[rt.status] or ''
      local hidden_tag = ''
      if not expanded then
        hidden_tag = ('(%d hidden)'):format(#sv.variants)
      end

      local label_part = '  ' .. name_upper .. ' '
      local right_part
      if status_label ~= '' and hidden_tag ~= '' then
        right_part = ' ' .. hidden_tag .. '  ' .. status_label .. '  '
      elseif status_label ~= '' then
        right_part = ' ' .. status_label .. '  '
      elseif hidden_tag ~= '' then
        right_part = ' ' .. hidden_tag .. '  '
      else
        right_part = '  '
      end

      local fill_cols = width - #label_part - #right_part
      if fill_cols < 1 then fill_cols = 1 end
      local fill = string.rep(icons.divider, fill_cols)
      local header_line = label_part .. fill .. right_part
      header_line = pad_to_width(header_line, width)

      push(header_line, { kind = 'spec_header', spec_name = rt.spec.name, rt = rt })
      local hdr_idx = #lines
      hl('AtelierSpecHeader', hdr_idx, 2, 2 + #name_upper)
      local fill_start = #label_part
      hl('AtelierDivider', hdr_idx, fill_start, fill_start + #fill)
      if right_part ~= '  ' then
        local right_start = fill_start + #fill
        if hidden_tag ~= '' then
          local pos = header_line:find(hidden_tag, right_start, true)
          if pos then hl('AtelierSubtle', hdr_idx, pos - 1, pos - 1 + #hidden_tag) end
        end
        if status_label ~= '' then
          local pos = header_line:find(status_label, right_start, true)
          if pos then
            hl(STATUS_GROUP[rt.status] or 'AtelierSubtle', hdr_idx, pos - 1, pos - 1 + #status_label)
          end
        end
      end

      if rt.status == 'failed' and rt.error then
        local err_line = pad_to_width('    ' .. rt.error, width)
        push(err_line, { kind = 'error', spec_name = rt.spec.name, rt = rt })
        hl('AtelierStatusErr', #lines, 4, 4 + #rt.error)
      end

      if expanded then
        local dw = vim.fn.strdisplaywidth
        for _, theme in ipairs(sv.variants) do
          local is_current = (state.current.spec_name == rt.spec.name)
            and (state.current.theme == theme)
          local marker = is_current and icons.current or ' '
          local left = '    ' .. marker .. ' ' .. theme
          local bg = M.background_of(rt.spec, theme)
          local right = ''
          if bg == 'dark' then
            right = icons.sep .. '  dark  '
          elseif bg == 'light' then
            right = icons.sep .. ' light  '
          else
            right = '  '
          end

          local pad_cols = width - dw(left) - dw(right)
          if pad_cols < 1 then pad_cols = 1 end
          local line = left .. string.rep(' ', pad_cols) .. right

          push(line, { kind = 'theme', spec_name = rt.spec.name, theme = theme, rt = rt })
          local idx = #lines

          local marker_start = 4
          hl('AtelierCurrent', idx, marker_start, marker_start + #marker)
          local name_start = marker_start + #marker + 1
          local name_group = is_current and 'AtelierCurrent' or 'AtelierTheme'
          hl(name_group, idx, name_start, name_start + #theme)
          if right ~= '  ' then
            local suffix_start = #line - #right
            hl('AtelierThemeBg', idx, suffix_start, #line)
          end
        end
      end
    end
  end

  -- Pad body to budget for stable footer position.
  while (#lines - body_first_line + 1) < body_budget do
    push('', { kind = 'spacer' })
  end

  -- ── info row ─────────────────────────────────────────────────────────
  push(rule_line(), { kind = 'rule' })
  hl('AtelierDivider', #lines, 2, -1)

  local info_line = '  '
  if hovered and hovered.kind == 'theme' and hovered.rt then
    local bg = M.background_of(hovered.rt.spec, hovered.theme)
    local bg_part = bg and (' ' .. icons.sep .. ' ' .. bg) or ''
    local status = hovered.rt.status
    local status_part = (status and status ~= 'installed' and status ~= 'unknown')
      and (' ' .. icons.sep .. ' ' .. status) or ''
    local source = hovered.rt.spec.url or hovered.rt.spec.name
    local short = source:match('github%.com[/:]([^/]+/[^/]+)$')
      or source:match('github%.com[/:]([^/]+/[^/]+)%.git$')
      or source
    short = short:gsub('%.git$', '')
    local left = hovered.theme .. bg_part .. status_part
    local right = short
    local pad = width - 2 - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right) - 2
    if pad < 1 then
      info_line = '  ' .. left
    else
      info_line = '  ' .. left .. string.rep(' ', pad) .. right
    end
  elseif hovered and hovered.kind == 'spec_header' and hovered.rt then
    local spec = hovered.rt.spec
    local count = #(hovered.rt.themes or {})
    local source = spec.url or spec.name
    local short = source:match('github%.com[/:]([^/]+/[^/]+)$') or source
    short = short:gsub('%.git$', '')
    info_line = ('  %s %s %d variants %s %s'):format(spec.name, icons.sep, count, icons.sep, short)
  end
  push(info_line, { kind = 'info' })
  local info_idx = #lines
  hl('AtelierSubtle', info_idx, 0, -1)
  if hovered and hovered.kind == 'theme' then
    hl('AtelierTheme', info_idx, 2, 2 + #hovered.theme)
  end

  -- ── footer ────────────────────────────────────────────────────────────
  push(rule_line(), { kind = 'rule' })
  hl('AtelierDivider', #lines, 2, -1)

  local footer_line, keycaps
  if state.ui.mode == 'filter' then
    footer_line = '  type to filter ' .. icons.sep .. ' <CR> apply ' .. icons.sep .. ' <Esc> cancel'
    keycaps = { '<CR>', '<Esc>' }
  else
    footer_line = '  <Space> preview ' .. icons.sep .. ' <CR> set ' .. icons.sep
      .. ' h/l fold ' .. icons.sep .. ' / filter ' .. icons.sep .. ' t bg ' .. icons.sep .. ' q'
    keycaps = { '<Space>', '<CR>', 'h/l', '/', 't', 'q' }
  end
  push(footer_line, { kind = 'footer' })
  local footer_idx = #lines
  hl('AtelierSubtle', footer_idx, 0, -1)
  local cursor_col = 2
  for _, cap in ipairs(keycaps) do
    local pos = footer_line:find(cap, cursor_col + 1, true)
    if pos then
      hl('AtelierKey', footer_idx, pos - 1, pos - 1 + #cap)
      cursor_col = pos - 1 + #cap
    end
  end

  return {
    lines = lines,
    highlights = highlights,
    rows = rows,
  }
end

---Toggle the fold state of one spec.
---@param state atelier.State
---@param spec_name string
function M.toggle_fold(state, spec_name)
  local rt = state.by_name[spec_name]
  if rt then
    if rt.expanded == nil then rt.expanded = false end
    rt.expanded = not rt.expanded
    state.bus:emit('state_changed')
  end
end

---@param state atelier.State
---@param spec_name string
---@param expanded boolean
function M.set_fold(state, spec_name, expanded)
  local rt = state.by_name[spec_name]
  if rt and rt.expanded ~= expanded then
    rt.expanded = expanded
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
---background `mode`. Returns the variant name or nil.
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
