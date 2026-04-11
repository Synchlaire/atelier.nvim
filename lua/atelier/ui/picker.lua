-- Pure render: State (+ width, height, hovered row) → lines, highlights,
-- and a 2D row-lookup table. No buffer access. Trivially testable.
--
-- The list body flows into 1, 2, or 3 columns when it overflows the
-- available body height. Column count is computed per render. Newspaper-
-- style layout: each spec group stays intact within one column (no
-- header reflow), and columns break between specs, not within them.
-- Cursor navigation inside the window uses `j`/`k` to move vertically
-- within a column and `h`/`l` to move between columns.
--
---@class atelier.PickerRow
---@field kind 'header'|'rule'|'filter'|'spec_header'|'theme'|'error'|'footer'|'info'|'spacer'
---@field spec_name string|nil
---@field theme string|nil
---@field rt atelier.ThemeRuntime|nil

---@class atelier.PickerView
---@field lines string[]
---@field highlights { line: integer, col_start: integer, col_end: integer, group: string }[]
---@field rows atelier.PickerRow[]                      Primary row per visual line (column 1 fallback).
---@field rows_by_col table<integer, atelier.PickerRow[]>  rows_by_col[visual_line] = { col1_row, col2_row, col3_row }
---@field col_byte_starts integer[]                     Byte offset of each column on any body line (shared across body rows).
---@field cols integer                                   Number of columns the body was laid out in.

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

local COLUMN_GAP = 2 -- visual columns between list columns
local CHROME_ROWS = 7 -- header + rule + filter + rule + info + rule + footer
local MAX_COLS = 3

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

---Pad a string to a given display width with trailing spaces.
local function pad_to_width(s, w)
  local dw = vim.fn.strdisplaywidth(s)
  if dw >= w then return s end
  return s .. string.rep(' ', w - dw)
end

---Build one spec group as a self-contained block. Line indices inside
---`highlights` are 1-based WITHIN the block (the caller shifts them when
---laying the block onto a column).
---@param sv table
---@param col_w integer   inner column width in display cells
---@param filter string
---@param icons table
---@param state atelier.State
---@return table  { lines=string[], rows=atelier.PickerRow[], highlights=[], height=integer }
local function build_spec_block(sv, col_w, filter, icons, state)
  local block = { lines = {}, rows = {}, highlights = {} }
  local function bpush(line, row)
    block.lines[#block.lines + 1] = line
    block.rows[#block.rows + 1] = row
  end
  local function bhl(group, line_idx, col_start, col_end)
    block.highlights[#block.highlights + 1] = {
      line = line_idx, col_start = col_start, col_end = col_end, group = group,
    }
  end

  local rt = sv.rt
  local expanded = rt.expanded
  if expanded == nil then expanded = true end
  if filter ~= '' and #sv.variants > 0 then expanded = true end

  -- Spec header.
  local name_upper = rt.spec.name:upper()
  local status_label = STATUS_LABEL[rt.status] or ''
  local hidden_tag = ''
  if not expanded then
    hidden_tag = ('(%d hidden)'):format(#sv.variants)
  end

  -- NOTE: Block content does NOT include a leading margin — the caller
  -- prepends the window-level margin (and column gaps) when stitching
  -- columns together. Keeping blocks margin-free means col_w is the
  -- actual usable width and byte offsets in col_byte_starts line up with
  -- the first character of content.

  local label_part = name_upper .. ' '
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

  local fill_cols = col_w - #name_upper - 1 - #right_part
  if fill_cols < 1 then fill_cols = 1 end
  local fill = string.rep(icons.divider, fill_cols)
  local header_line = label_part .. fill .. right_part
  header_line = pad_to_width(header_line, col_w)

  bpush(header_line, { kind = 'spec_header', spec_name = rt.spec.name, rt = rt })
  local hdr_idx = #block.lines
  bhl('AtelierSpecHeader', hdr_idx, 0, #name_upper)
  local fill_start = #name_upper + 1
  bhl('AtelierDivider', hdr_idx, fill_start, fill_start + #fill)
  if right_part ~= '' then
    local right_start = fill_start + #fill
    if hidden_tag ~= '' then
      local pos = header_line:find(hidden_tag, right_start, true)
      if pos then bhl('AtelierSubtle', hdr_idx, pos - 1, pos - 1 + #hidden_tag) end
    end
    if status_label ~= '' then
      local pos = header_line:find(status_label, right_start, true)
      if pos then
        bhl(STATUS_GROUP[rt.status] or 'AtelierSubtle', hdr_idx, pos - 1, pos - 1 + #status_label)
      end
    end
  end

  if rt.status == 'failed' and rt.error then
    local err_line = pad_to_width('  ' .. rt.error, col_w)
    bpush(err_line, { kind = 'error', spec_name = rt.spec.name, rt = rt })
    bhl('AtelierStatusErr', #block.lines, 2, 2 + #rt.error)
  end

  if expanded then
    local dw = vim.fn.strdisplaywidth
    for _, theme in ipairs(sv.variants) do
      local is_current = (state.current.spec_name == rt.spec.name)
        and (state.current.theme == theme)
      local marker = is_current and icons.current or ' '
      local left = marker .. ' ' .. theme
      local bg = M.background_of(rt.spec, theme)
      local right = ''
      if bg == 'dark' then
        right = icons.sep .. '  dark'
      elseif bg == 'light' then
        right = icons.sep .. ' light'
      end

      local pad_cols = col_w - dw(left) - dw(right)
      if pad_cols < 1 then pad_cols = 1 end
      local line = left .. string.rep(' ', pad_cols) .. right

      bpush(line, { kind = 'theme', spec_name = rt.spec.name, theme = theme, rt = rt })
      local idx = #block.lines

      bhl('AtelierCurrent', idx, 0, #marker)
      local name_start = #marker + 1
      local name_group = is_current and 'AtelierCurrent' or 'AtelierTheme'
      bhl(name_group, idx, name_start, name_start + #theme)
      if right ~= '' then
        local suffix_start = #line - #right
        bhl('AtelierThemeBg', idx, suffix_start, #line)
      end
    end
  end

  block.height = #block.lines
  return block
end

---Pack blocks into N columns greedy, newspaper-style. Returns a list
---of columns, each being a list of blocks. A block that's taller than
---the budget gets its own column (and overflows — the list scrolls).
---@param blocks table[]
---@param n_cols integer
---@param budget integer
---@return table[][]
local function pack_columns(blocks, n_cols, budget)
  local cols = {}
  for i = 1, n_cols do cols[i] = { blocks = {}, height = 0 } end
  local ci = 1
  for _, b in ipairs(blocks) do
    if ci > n_cols then ci = n_cols end -- overflow into last column
    if cols[ci].height > 0 and cols[ci].height + b.height > budget and ci < n_cols then
      ci = ci + 1
    end
    table.insert(cols[ci].blocks, b)
    cols[ci].height = cols[ci].height + b.height
  end
  return cols
end

---@param state atelier.State
---@param width integer    Window inner width in display cells.
---@param height integer   Window inner height in display cells.
---@param hovered atelier.PickerRow|nil
---@return atelier.PickerView
function M.render(state, width, height, hovered)
  local lines = {}
  local highlights = {}
  local rows = {}
  local rows_by_col = {}
  local icons = Icons.active
  local filter = state.ui.filter
  width = width or 72
  height = height or 28

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

  -- ── pre-compute spec_views (same filtering logic as before) ──────────
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

  -- ── body: column layout ──────────────────────────────────────────────
  local body_budget = height - CHROME_ROWS
  if body_budget < 4 then body_budget = 4 end

  -- First pass: build blocks at full width to estimate total body height.
  -- Margins: 2 on the left, 2 on the right = 4 chars.
  local full_col_w = width - 4
  local blocks_full = {}
  for _, sv in ipairs(spec_views) do
    if sv.visible then
      blocks_full[#blocks_full + 1] = build_spec_block(sv, full_col_w, filter, icons, state)
    end
  end

  local total_body_h = 0
  for _, b in ipairs(blocks_full) do total_body_h = total_body_h + b.height end

  -- Decide column count.
  local n_cols = 1
  if total_body_h > body_budget then n_cols = 2 end
  if total_body_h > body_budget * 2 then n_cols = 3 end
  if n_cols > MAX_COLS then n_cols = MAX_COLS end

  -- Second pass: if multi-column, rebuild blocks at the narrower width.
  local blocks
  local col_w
  if n_cols == 1 then
    blocks = blocks_full
    col_w = full_col_w
  else
    col_w = math.floor((width - 4 - (n_cols - 1) * COLUMN_GAP) / n_cols)
    if col_w < 20 then
      -- Terminal too narrow for the chosen column count; fall back.
      n_cols = math.max(1, math.floor((width - 4 + COLUMN_GAP) / (20 + COLUMN_GAP)))
      col_w = math.floor((width - 4 - (n_cols - 1) * COLUMN_GAP) / n_cols)
    end
    blocks = {}
    for _, sv in ipairs(spec_views) do
      if sv.visible then
        blocks[#blocks + 1] = build_spec_block(sv, col_w, filter, icons, state)
      end
    end
  end

  -- Pack into columns.
  local packed = pack_columns(blocks, n_cols, body_budget)

  -- Compute per-column byte start on each body line. The list has a
  -- 2-char left margin, then col1 (col_w cells), then GAP spaces, then
  -- col2, etc.
  local col_byte_starts = {}
  local cursor = 2 -- 2-char left margin
  for c = 1, n_cols do
    col_byte_starts[c] = cursor
    cursor = cursor + col_w
    if c < n_cols then cursor = cursor + COLUMN_GAP end
  end

  -- Merge columns row-by-row.
  local body_height = 0
  for _, col in ipairs(packed) do
    if col.height > body_height then body_height = col.height end
  end
  if body_height == 0 then body_height = 1 end -- at least one empty row

  -- For each body visual row, walk each column and stitch the line.
  local empty_col = string.rep(' ', col_w)
  local body_first_line = #lines + 1
  for vr = 1, body_height do
    local merged = string.rep(' ', 2) -- left margin
    local row_triple = {}
    local primary_row = { kind = 'spacer' }

    for c = 1, n_cols do
      if c > 1 then merged = merged .. string.rep(' ', COLUMN_GAP) end
      local col_byte_start = #merged

      -- Resolve which block/line within column c maps to this vr.
      local remaining = vr
      local col_content = nil
      local col_row = nil
      for _, b in ipairs(packed[c].blocks) do
        if remaining <= b.height then
          col_content = b.lines[remaining]
          col_row = b.rows[remaining]
          -- Emit this block's highlights for the matching line into globals.
          for _, h in ipairs(b.highlights) do
            if h.line == remaining then
              local cs = h.col_start + col_byte_start
              local ce = h.col_end >= 0 and (h.col_end + col_byte_start) or -1
              hl(h.group, #lines + 1, cs, ce)
            end
          end
          break
        else
          remaining = remaining - b.height
        end
      end

      if col_content == nil then
        col_content = empty_col
        col_row = { kind = 'spacer' }
      end
      merged = merged .. col_content
      row_triple[c] = col_row
      if c == 1 then primary_row = col_row end
    end

    push(merged, primary_row)
    rows_by_col[#lines] = row_triple
  end

  -- If body was short (less than budget), pad with empty rows to keep
  -- footer position stable across fold/filter toggles.
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
      .. ' / filter ' .. icons.sep .. ' t bg ' .. icons.sep .. ' I U C ' .. icons.sep .. ' q'
    keycaps = { '<Space>', '<CR>', '/', 't', 'I', 'U', 'C', 'q' }
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
    rows_by_col = rows_by_col,
    col_byte_starts = col_byte_starts,
    cols = n_cols,
  }
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
