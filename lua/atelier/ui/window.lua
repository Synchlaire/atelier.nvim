-- Floating window lifecycle. Single list pane — the preview pane is
-- deliberately disabled for now; when/if it comes back it'll be a
-- separate, opt-in component. Owns the buffer + window handles, applies
-- a PickerView with diffed writes, and exposes hooks the keymap and
-- cursor-move handlers attach to.
--
local M = {}

local NS = vim.api.nvim_create_namespace('atelier.picker')

local LIST_W = 80
local LIST_H = 28

---@class atelier.Window
---@field buf integer
---@field win integer
---@field width integer        inner width of the pane (no border)
---@field height integer       inner height of the pane (no border)
---@field state atelier.State
---@field rows atelier.PickerRow[]
---@field prev_lines string[]
---@field hovered_row atelier.PickerRow|nil
---@field on_close fun()|nil
---@field on_cursor fun(row: atelier.PickerRow|nil)|nil
---@field private _bus_listener fun()
---@field private _closed boolean
local Window = {}
Window.__index = Window

---@param state atelier.State
---@return atelier.Window
function M.open(state)
  local width = math.min(LIST_W, math.floor(vim.o.columns * 0.8))
  local height = math.min(LIST_H, math.floor(vim.o.lines * 0.8))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'atelier', { buf = buf })

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
    width = width,
    height = height,
    state = state,
    rows = {},
    prev_lines = {},
    hovered_row = nil,
    on_close = nil,
    on_cursor = nil,
    _closed = false,
  }, Window)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      if self._closed then return end
      local row = self:current_row()
      self.hovered_row = row
      if self.on_cursor then self.on_cursor(row) end
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function() self:_dispose() end,
  })

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

  local mod_ok = pcall(vim.api.nvim_set_option_value, 'modifiable', true, { buf = self.buf })
  if not mod_ok then return end

  local n_prev = #prev
  local n_next = #next_lines
  local first_diff = 1
  while first_diff <= n_prev
    and first_diff <= n_next
    and prev[first_diff] == next_lines[first_diff] do
    first_diff = first_diff + 1
  end

  if first_diff > n_prev and first_diff > n_next then
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
  local view = Picker.render(self.state, self.width, self.height, self.hovered_row)
  apply_diff(self, view)
end

---Re-render triggered by cursor move (info row depends on hovered_row).
---@param row atelier.PickerRow|nil
function Window:refresh_info(row)
  self.hovered_row = row
  self:render()
end

---@return atelier.PickerRow|nil
function Window:current_row()
  if not vim.api.nvim_win_is_valid(self.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
  return self.rows[lnum]
end

---Move the cursor vertically by `delta` lines, skipping non-selectable rows.
---@param delta integer
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
end

function Window:close()
  if vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
end

return M
