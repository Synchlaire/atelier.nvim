-- Volt-backed control strip (Light / Dark / Auto + workshop actions).
--
-- Two halves:
--   * `M.model(state, width, opts)` is a pure description of the strip as
--     rows of `{ text, group, action }` segments. Without Volt the picker
--     renders it as plain buffer text.
--   * `M.attach/draw/detach` draw the same model with Volt's gen_data/redraw
--     as virtual text over blank buffer lines and dispatch mouse clicks
--     through a buffer-local `<LeftMouse>` map. Volt.events (global
--     vim.on_key, mouse options) and Volt.run are never touched.
--
-- `require('volt')` happens only in `M.load()`, called when the picker opens.
--
local Icons = require('atelier.ui.icons')

local M = {}

M.NS = vim.api.nvim_create_namespace('atelier.volt')
M.MISSING_HINT = '  Clickable controls need nvzone/volt (add it as a dependency).'

local MODES = {
  { 'light', 'Light' },
  { 'dark', 'Dark ' },
  { 'auto', 'Auto ' },
}

local OPS = {
  { 'I', 'Install' },
  { 'U', 'Update' },
  { 'C', 'Clean' },
  { '?', 'Actions' },
}

local VALID = { light = true, dark = true, auto = true }

---@return table|nil volt  nil when nvzone/volt is not installed.
function M.load()
  local ok, volt = pcall(require, 'volt')
  if ok and type(volt) == 'table' and volt.gen_data and volt.redraw then return volt end
  return nil
end

---@param available boolean
---@return integer
function M.row_count(available)
  return available and 3 or 4
end

---@param state atelier.State
---@return 'light'|'dark'|'auto' applied, 'light'|'dark'|'auto'|nil draft
function M.modes(state)
  local applied = state.current and state.current.mode
  if not VALID[applied] then
    applied = state.config and state.config.mode
  end
  if not VALID[applied] then applied = 'auto' end
  local draft = state.ui and state.ui.previewed and state.ui.previewed.mode
  if not VALID[draft] then draft = nil end
  return applied, draft
end

---Whether the theme in focus follows desktop light/dark. nil when unknown.
---@param state atelier.State
---@return boolean|nil
local function supports_auto(state)
  local active = (state.ui and state.ui.previewed) or state.current
  local rt = active and active.spec_name and state.by_name and state.by_name[active.spec_name]
  if not rt then return nil end
  local ok, selection = pcall(require, 'atelier.selection')
  if ok and type(selection.supports_auto) == 'function' then
    local ok2, res = pcall(selection.supports_auto, rt.spec)
    if ok2 then return res and true or false end
  end
  local spec = rt.spec
  if spec.auto then return true end
  local has_light, has_dark = false, false
  for _, bg in pairs(spec.backgrounds or {}) do
    if bg == 'light' then has_light = true end
    if bg == 'dark' then has_dark = true end
  end
  return has_light and has_dark
end

---Clip a row of segments to `width` display cells.
local function clip(row, width)
  local out, used = {}, 0
  for _, seg in ipairs(row) do
    local w = vim.fn.strdisplaywidth(seg[1])
    if used + w <= width then
      out[#out + 1] = seg
      used = used + w
    else
      local room = width - used
      if room > 0 then
        local text = vim.fn.strcharpart(seg[1], 0, room)
        out[#out + 1] = { text, seg[2], seg[3] }
      end
      break
    end
  end
  return out
end

local function row_width(row)
  local w = 0
  for _, seg in ipairs(row) do w = w + vim.fn.strdisplaywidth(seg[1]) end
  return w
end

---@param state atelier.State
---@param width integer
---@param opts { interactive: boolean }|nil
---@return table[][] rows  each row is a list of { text, group, action|nil }
function M.model(state, width, opts)
  opts = opts or {}
  local icons = Icons.active
  local applied, draft = M.modes(state)
  local rows = {}

  -- Row 1: mode buttons. Applied is inverted; preview draft adds underline
  -- and its own glyph so state never depends on colour alone.
  local function mode_row(full)
    local row = { { '  ', 'AtelierNormal' } }
    for i, m in ipairs(MODES) do
      local marker = ' '
      local group = 'AtelierControl'
      if m[1] == draft then
        marker, group = icons.preview, 'AtelierControlDraft'
      elseif m[1] == applied then
        marker, group = icons.current, 'AtelierControlActive'
      end
      local label = full and m[2] or m[2]:sub(1, 1)
      local text = full and ('[%s %s]'):format(marker, label) or ('[%s%s]'):format(marker, label)
      if i > 1 then row[#row + 1] = { ' ', 'AtelierNormal' } end
      row[#row + 1] = { text, group, { kind = 'mode', mode = m[1] } }
    end
    return row
  end
  local r1 = mode_row(true)
  if row_width(r1) > width then r1 = mode_row(false) end
  rows[1] = clip(r1, width)

  -- Row 2: applied vs preview draft vs effective background (+ capability).
  local bg = vim.o.background
  local fixed = supports_auto(state) == false
  local function status_row(full)
    local row = { { '  ', 'AtelierNormal' } }
    local function add(t, g) row[#row + 1] = { t, g or 'AtelierSubtle' } end
    if full then
      add('applied '); add(applied, 'AtelierCurrent')
      add(' ' .. icons.sep .. ' preview ')
      if draft then add(draft, 'AtelierPreview') else add('-') end
      add(' ' .. icons.sep .. ' bg '); add(bg, 'AtelierTheme')
    else
      add(applied, 'AtelierCurrent')
      if draft then add(' > '); add(draft, 'AtelierPreview') end
      add(' ' .. icons.sep .. ' bg ' .. bg, 'AtelierTheme')
    end
    if fixed then add(' ' .. icons.sep .. ' fixed', 'AtelierStatusBusy') end
    return row
  end
  local r2 = status_row(true)
  if row_width(r2) > width then r2 = status_row(false) end
  rows[2] = clip(r2, width)

  -- Row 3: operations (or progress while one is running).
  local op = state.operation
  if op then
    local ascii = Icons.active == Icons.ascii
    local total = math.max(op.total or 0, 1)
    local filled = math.floor(10 * (op.completed or 0) / total)
    local meter = string.rep(ascii and '#' or '█', filled)
      .. string.rep(ascii and '.' or '░', 10 - filled)
    local text = ('  %s %d/%d'):format((op.kind or 'busy'):upper(), op.completed or 0, op.total or 0)
    local row = {
      { text, 'AtelierStatusBusy' },
      { ' ' .. meter, 'AtelierStatusBusy' },
    }
    if (op.failed or 0) > 0 then
      row[#row + 1] = { (' %d failed'):format(op.failed), 'AtelierStatusErr' }
    end
    rows[3] = clip(row, width)
  else
    local function ops_row(full)
      local row = { { '  ', 'AtelierNormal' } }
      for i, o in ipairs(OPS) do
        if i > 1 then row[#row + 1] = { ' ', 'AtelierNormal' } end
        local text = full and ('[%s %s]'):format(o[1], o[2]) or ('[%s]'):format(o[1])
        row[#row + 1] = { text, 'AtelierControl', { kind = 'key', key = o[1] } }
      end
      return row
    end
    local r3 = ops_row(true)
    if row_width(r3) > width then r3 = ops_row(false) end
    rows[3] = clip(r3, width)
  end

  if not opts.interactive then
    rows[4] = clip({ { M.MISSING_HINT, 'AtelierStatusBusy' } }, width)
  end
  return rows
end

---@param win table atelier.Window
---@param action { kind: string, mode: string|nil, key: string|nil }
local function run_action(win, action)
  if action.kind == 'mode' then
    win:set_mode(action.mode)
  elseif action.kind == 'key' then
    win:invoke_key(action.key)
  end
end

---Volt section lines. Fresh tables on every call: Volt mutates them.
local function volt_lines(win)
  local model = M.model(win.state, win.width, { interactive = true })
  local out = {}
  for _, row in ipairs(model) do
    local line = {}
    for _, seg in ipairs(row) do
      local mark = { seg[1], seg[2] }
      if seg[3] then
        local action = seg[3]
        mark[3] = function() run_action(win, action) end
      end
      line[#line + 1] = mark
    end
    out[#out + 1] = line
  end
  return out
end

local function find_click(clickables, col)
  for _, item in ipairs(clickables or {}) do
    if col >= item.col_start and (col < item.col_end or col == item.col_start) then
      return item
    end
  end
end

---Buffer-local mouse dispatch. Never changes 'mouse' or registers on_key.
local function map_mouse(win)
  local buf = win.buf
  local function click()
    local pos = vim.fn.getmousepos()
    if pos.winid ~= win.win then
      if pos.winid > 0 and vim.api.nvim_win_is_valid(pos.winid) then
        pcall(vim.api.nvim_set_current_win, pos.winid)
      end
      return
    end
    local lnum, col = pos.line, pos.wincol - 1
    local vstate = require('volt.state')[buf]
    local item = vstate and find_click(vstate.clickables[lnum], col)
    if item and type(item.actions) == 'function' then
      local ok, err = pcall(item.actions)
      if not ok then
        win.state.ui.message = ('Control failed: %s'):format(tostring(err))
        win.state.bus:emit('state_changed')
      end
      return
    end
    local row = win.rows[lnum]
    if row and (row.kind == 'theme' or row.kind == 'spec_header') then
      pcall(vim.api.nvim_win_set_cursor, win.win, { lnum, 2 })
    end
  end
  local opts = { buffer = buf, nowait = true, silent = true, desc = 'atelier: click' }
  vim.keymap.set('n', '<LeftMouse>', click, opts)
  vim.keymap.set('n', '<2-LeftMouse>', click, opts)
  for _, key in ipairs({ '<LeftDrag>', '<LeftRelease>', '<2-LeftRelease>' }) do
    vim.keymap.set('n', key, '<Nop>', opts)
  end
end

---@param win table atelier.Window
---@param volt table
function M.attach(win, volt)
  local section = { name = 'controls', lines = function() return volt_lines(win) end }
  volt.gen_data({ { buf = win.buf, layout = { section }, xpad = 0, ns = M.NS } })
  win._volt = { mod = volt, section = section }
  map_mouse(win)
end

---Redraw (or clear, when the view has no strip, e.g. the help card).
---@param win table
---@param view atelier.PickerView
function M.draw(win, view)
  local v = win._volt
  if not v or not vim.api.nvim_buf_is_valid(win.buf) then return end
  if view.controls then
    v.section.row = view.controls.first - 1
    v.mod.redraw(win.buf, 'controls')
  else
    pcall(vim.api.nvim_buf_clear_namespace, win.buf, M.NS, 0, -1)
    local vs = require('volt.state')[win.buf]
    if vs then vs.clickables, vs.hoverables = {}, {} end
  end
end

---@param win table
function M.detach(win)
  if not win._volt then return end
  local ok, vs = pcall(require, 'volt.state')
  if ok then vs[win.buf] = nil end
  if vim.api.nvim_buf_is_valid(win.buf) then
    pcall(vim.api.nvim_buf_clear_namespace, win.buf, M.NS, 0, -1)
  end
  win._volt = nil
end

return M
