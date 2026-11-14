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

local Controls = require('atelier.ui.volt')

---Currently open window (module singleton): reopening closes it first.
---@type atelier.Window|nil
local current

local function desired_height(state, control_rows)
  local Manager = require('atelier.manager')
  local rows = 7 + control_rows
  for _, rt in ipairs(state.themes) do
    rows = rows + 1
    if rt.status == 'failed' and rt.error then rows = rows + 1 end
    if rt.expanded then rows = rows + math.max(1, #Manager.discover(state, rt)) end
  end
  -- The picker never renders fewer than 4 body rows; keep the whole strip visible.
  return math.max(7 + control_rows + 4, math.min(LIST_H, rows))
end

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
---@field on_mode fun(mode: 'light'|'dark'|'auto'): boolean|nil  set by the owner; Light/Dark/Auto controls call it
---@field volt boolean  true when the control strip is drawn by Volt (clickable)
---@field private _bus_listener fun()
---@field private _closed boolean
local Window = {}
Window.__index = Window

---@param state atelier.State
---@param control_rows integer
---@return integer width, integer height, integer row, integer col
local function layout(state, control_rows)
  local width = math.max(1, math.min(LIST_W, math.floor(vim.o.columns * 0.8)))
  local height = math.max(1, math.min(desired_height(state, control_rows), math.floor(vim.o.lines * 0.8)))
  return width, height,
    math.max(0, math.floor((vim.o.lines - height) / 2)),
    math.max(0, math.floor((vim.o.columns - width) / 2))
end

---@return atelier.Window|nil
function M.get() return current end

---@param state atelier.State
---@return atelier.Window
function M.open(state)
  if current then
    current:close()
    current = nil
  end

  -- Volt is required lazily, only when a picker opens.
  local volt = Controls.load()
  local control_rows = Controls.row_count(volt ~= nil)
  local width, height, row, col = layout(state, control_rows)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'atelier', { buf = buf })

  local win_ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'single',
    title = ' ATELIER · WORKSHOP ',
    title_pos = 'center',
  })
  if not win_ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    error('atelier: could not open the workshop window: ' .. tostring(win), 0)
  end

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
    prev_lines = { '' }, -- a fresh buffer holds one empty line
    hovered_row = nil,
    on_close = nil,
    on_cursor = nil,
    on_mode = nil,
    volt = volt ~= nil,
    control_rows = control_rows,
    _closed = false,
  }, Window)
  current = self

  -- Anything below can raise (Volt attach, autocmds). Never leave a
  -- half-built float behind: tear it down and surface a clear error.
  local ok, err = pcall(function()
    if volt then Controls.attach(self, volt) end

    self._group = vim.api.nvim_create_augroup('atelier.window.' .. buf, { clear = true })
    vim.api.nvim_create_autocmd('VimResized', {
      group = self._group,
      callback = function() self:resize() end,
    })

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
  end)
  if not ok then
    self:_dispose()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if current == self then current = nil end
    error('atelier: could not set up the workshop window: ' .. tostring(err), 0)
  end

  return self
end

function Window:_dispose()
  if self._closed then return end
  self._closed = true
  if current == self then current = nil end
  if self._group then
    pcall(vim.api.nvim_del_augroup_by_id, self._group)
    self._group = nil
  end
  Controls.detach(self)
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
  local view = Picker.render(self.state, self.width, self.height, self.hovered_row, {
    controls = Controls.model(self.state, self.width, { interactive = self.volt }),
    interactive = self.volt,
  })
  apply_diff(self, view)
  if self.volt then Controls.draw(self, view) end
end

---Recompute geometry after the terminal changed size.
function Window:resize()
  if self._closed or not vim.api.nvim_win_is_valid(self.win) then return end
  local width, height, row, col = layout(self.state, self.control_rows)
  self.width, self.height = width, height
  pcall(vim.api.nvim_win_set_config, self.win, {
    relative = 'editor', width = width, height = height, row = row, col = col,
  })
  -- Widths changed: diff against the real buffer, not the cached lines.
  self.prev_lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  self:render()
end

---Ask the owner to switch the preview mode (Light/Dark/Auto).
---@param mode 'light'|'dark'|'auto'
---@return boolean
function Window:set_mode(mode)
  local state = self.state
  local ok_call, ok = true, false
  state.ui.message = nil
  if self.on_mode then
    ok_call, ok = pcall(self.on_mode, mode)
    if not ok_call then
      state.ui.message = ('Mode %s failed: %s'):format(mode, tostring(ok))
      ok = false
    end
  else
    state.ui.message = 'Mode preview is not available here.'
  end
  if ok ~= true and not state.ui.message then
    state.ui.message = ('Cannot preview %s mode.'):format(mode)
  end
  state.bus:emit('state_changed')
  return ok == true
end

---Run the buffer-local normal-mode mapping for `key`, so clickable actions
---share the keyboard implementation.
---@param key string
---@return boolean
function Window:invoke_key(key)
  if self._closed or not vim.api.nvim_win_is_valid(self.win) then return false end
  local map = vim.api.nvim_buf_call(self.buf, function()
    return vim.fn.maparg(key, 'n', false, true)
  end)
  if type(map) ~= 'table' or type(map.callback) ~= 'function' then
    self.state.ui.message = ('No action bound to %s.'):format(key)
    self.state.bus:emit('state_changed')
    return false
  end
  local ok, err = pcall(vim.api.nvim_win_call, self.win, map.callback)
  if not ok then
    self.state.ui.message = ('Action %s failed: %s'):format(key, tostring(err))
    self.state.bus:emit('state_changed')
  end
  return ok
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
