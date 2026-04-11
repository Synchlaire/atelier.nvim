-- Floating window lifecycle ONLY. Owns the buffer + window handles, knows
-- how to apply a PickerView with diffed line writes, and exposes hooks the
-- keymap/preview modules attach to. No state lives in the buffer.
--
local M = {}

local NS = vim.api.nvim_create_namespace('atelier.picker')

---@class atelier.Window
---@field buf integer
---@field win integer
---@field state atelier.State
---@field rows atelier.PickerRow[]
---@field prev_lines string[]
---@field on_close fun()|nil
---@field on_cursor fun(row: atelier.PickerRow|nil)|nil
---@field private _bus_listener fun()        Reference held so we can unsubscribe on close.
---@field private _closed boolean
local Window = {}
Window.__index = Window

---@param state atelier.State
---@return atelier.Window
function M.open(state)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'atelier', { buf = buf })

  local width = math.min(72, math.floor(vim.o.columns * 0.6))
  local height = math.min(24, math.floor(vim.o.lines * 0.6))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'single',
    title = ' ATELIER ',
    title_pos = 'center',
  })

  vim.api.nvim_set_option_value('cursorline', true, { win = win })
  vim.api.nvim_set_option_value('wrap', false, { win = win })
  vim.api.nvim_set_option_value('winhighlight',
    'NormalFloat:AtelierNormal,FloatBorder:AtelierBorder,FloatTitle:AtelierTitle,CursorLine:AtelierCursorLine',
    { win = win })

  ---@type atelier.Window
  local self = setmetatable({
    buf = buf,
    win = win,
    state = state,
    rows = {},
    prev_lines = {},
    on_close = nil,
    on_cursor = nil,
    _closed = false,
  }, Window)

  -- CursorMoved drives both highlighting and the preview module.
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      if self._closed then return end
      if self.on_cursor then self.on_cursor(self:current_row()) end
    end,
  })

  -- Only BufWipeout means the picker is actually gone — BufLeave fires on
  -- *any* buffer switch and would prematurely cleanup() while the picker
  -- is still alive.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function() self:_dispose() end,
  })

  -- Re-render whenever state changes. Hold a reference so we can
  -- unsubscribe on dispose — anonymous listeners would otherwise leak
  -- across every open/close cycle and fire against wiped buffers.
  self._bus_listener = function() self:render() end
  state.bus:on('state_changed', self._bus_listener)

  return self
end

function Window:_dispose()
  if self._closed then return end
  self._closed = true
  if self._bus_listener then
    self.state.bus:off('state_changed', self._bus_listener)
    self._bus_listener = nil
  end
  if self.on_close then
    pcall(self.on_close)
    self.on_close = nil
  end
end

---@param view atelier.PickerView
local function apply_diff(self, view)
  if self._closed or not vim.api.nvim_buf_is_valid(self.buf) then return end

  local prev = self.prev_lines
  local next_lines = view.lines

  -- Wrap modifiable mutations in pcall so a transient race (e.g. buffer
  -- becoming invalid mid-render after a deferred state_changed fires)
  -- can't escape and crash the picker.
  local mod_ok = pcall(vim.api.nvim_set_option_value, 'modifiable', true, { buf = self.buf })
  if not mod_ok then return end

  -- Find the first and last differing rows. For typical incremental
  -- updates (a status flip on one row) only that one line gets rewritten,
  -- which is what eliminates the flicker themify has.
  local n_prev = #prev
  local n_next = #next_lines
  local first_diff = 1
  while first_diff <= n_prev
    and first_diff <= n_next
    and prev[first_diff] == next_lines[first_diff] do
    first_diff = first_diff + 1
  end

  if first_diff > n_prev and first_diff > n_next then
    -- Identical: nothing to do.
    pcall(vim.api.nvim_set_option_value, 'modifiable', false, { buf = self.buf })
    return
  end

  local last_diff_prev = n_prev
  local last_diff_next = n_next
  while last_diff_prev >= first_diff
    and last_diff_next >= first_diff
    and prev[last_diff_prev] == next_lines[last_diff_next] do
    last_diff_prev = last_diff_prev - 1
    last_diff_next = last_diff_next - 1
  end

  local replacement = {}
  for i = first_diff, last_diff_next do
    replacement[#replacement + 1] = next_lines[i]
  end
  pcall(vim.api.nvim_buf_set_lines, self.buf, first_diff - 1, last_diff_prev, false, replacement)
  pcall(vim.api.nvim_set_option_value, 'modifiable', false, { buf = self.buf })

  -- Highlights: easier to clear & re-apply than to diff. They're cheap.
  pcall(vim.api.nvim_buf_clear_namespace, self.buf, NS, 0, -1)
  for _, h in ipairs(view.highlights) do
    pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, h.line, h.col_start, {
      end_col = h.col_end >= 0 and h.col_end or nil,
      end_line = h.col_end >= 0 and nil or h.line + 1,
      hl_group = h.group,
    })
  end

  self.prev_lines = next_lines
  self.rows = view.rows
end

function Window:render()
  if self._closed or not vim.api.nvim_buf_is_valid(self.buf) then return end
  local Picker = require('atelier.ui.picker')
  local w = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) or 72
  local view = Picker.render(self.state, w)
  apply_diff(self, view)
end

---@return atelier.PickerRow|nil
function Window:current_row()
  if not vim.api.nvim_win_is_valid(self.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
  return self.rows[lnum]
end

---Move the cursor by `delta` lines, skipping rows the user can't act on
---(spacers, headers, footers, filter input). Section headers ARE
---selectable because <CR> on them toggles the bucket.
---@param delta integer  +1 for j, -1 for k
function Window:move_by(delta)
  if not vim.api.nvim_win_is_valid(self.win) then return end
  local function selectable(row)
    if not row then return false end
    return row.kind == 'theme' or row.kind == 'spec_header'
  end

  local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
  local n = #self.rows
  local i = lnum + delta
  while i >= 1 and i <= n do
    if selectable(self.rows[i]) then
      pcall(vim.api.nvim_win_set_cursor, self.win, { i, 2 })
      return
    end
    i = i + delta
  end
  -- No selectable row in that direction; leave cursor where it is.
end

function Window:close()
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
end

return M
