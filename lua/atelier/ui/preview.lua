-- Debounced hover preview with restore-on-cancel.
--
-- Snapshots the user's current colorscheme when the picker opens. Hovering
-- a theme schedules a deferred :colorscheme; if the cursor moves again
-- before the delay fires, the scheduled load is cancelled. Closing the
-- picker without committing restores the snapshot.
--
local Loader = require('atelier.loader')
local Manager = require('atelier.manager')

local M = {}

---@class atelier.Preview
---@field state atelier.State
---@field snapshot string|nil       :colorscheme value at picker-open time.
---@field snapshot_background 'dark'|'light'  vim.o.background at picker-open time.
---@field pending integer|nil       defer_fn timer id.
---@field committed boolean         True once the user pressed <CR>.
---@field current_row_key string|nil  spec_name|theme of the row currently shown.
local Preview = {}
Preview.__index = Preview

---@param state atelier.State
---@return atelier.Preview
function M.new(state)
  local self = setmetatable({
    state = state,
    snapshot = vim.g.colors_name,
    snapshot_background = vim.o.background,
    pending = nil,
    committed = false,
    current_row_key = nil,
  }, Preview)
  return self
end

---@param row atelier.PickerRow|nil
function Preview:on_cursor(row)
  if not row or row.kind ~= 'theme' or not row.rt then return end
  if row.rt.status ~= 'installed' then return end

  local key = row.spec_name .. '|' .. row.theme
  if key == self.current_row_key then return end
  self.current_row_key = key

  if self.pending then
    pcall(vim.fn.timer_stop, self.pending)
    self.pending = nil
  end

  local delay = self.state.config.preview_delay_ms
  local spec_name, theme = row.spec_name, row.theme
  self.pending = vim.fn.timer_start(delay, function()
    self.pending = nil
    local rt = self.state.by_name[spec_name]
    if not rt then return end
    -- Don't run on_load during preview — it's not a commit.
    Loader.load(rt.spec, theme, nil)
  end)
end

---Commit the currently-previewed theme as the active one. Persists.
---@param row atelier.PickerRow|nil
---@return boolean
function Preview:commit(row)
  if not row or row.kind ~= 'theme' or not row.rt then return false end
  if row.rt.status ~= 'installed' then
    vim.notify('[atelier] theme not installed: ' .. row.theme, vim.log.levels.WARN)
    return false
  end

  if self.pending then
    pcall(vim.fn.timer_stop, self.pending)
    self.pending = nil
  end

  local ok, err = Loader.load(row.rt.spec, row.theme, self.state.config.on_load)
  if not ok then
    vim.notify('[atelier] failed to load theme: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  -- Capture vim.o.background only when something declared an opinion —
  -- either the spec or a prior `B` toggle that changed it away from the
  -- snapshot. nil means "atelier had no opinion, leave it alone".
  local bg = nil
  if Loader.declared_background(row.rt.spec, row.theme)
    or vim.o.background ~= self.snapshot_background then
    bg = vim.o.background
  end

  self.state.current = { spec_name = row.spec_name, theme = row.theme, background = bg }
  self.state.last_good = { spec_name = row.spec_name, theme = row.theme, background = bg }
  self.committed = true
  if self.state.config.persist then
    require('atelier.persist').write(self.state.config.data_dir, self.state.current)
  end
  self.state.bus:emit('state_changed')
  return true
end

---Restore the snapshot if nothing was committed. Called from on_close.
function Preview:cleanup()
  if self.pending then
    pcall(vim.fn.timer_stop, self.pending)
    self.pending = nil
  end
  if not self.committed then
    -- Restore background BEFORE the colorscheme so colorschemes that
    -- branch on it pick up the original mode at load time.
    if vim.o.background ~= self.snapshot_background then
      vim.o.background = self.snapshot_background
    end
    if self.snapshot and self.snapshot ~= vim.g.colors_name then
      pcall(vim.cmd.colorscheme, self.snapshot)
    end
  end
end

return M
