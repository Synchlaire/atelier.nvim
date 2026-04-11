-- On-demand preview with restore-on-cancel.
--
-- Snapshots the user's current colorscheme when the picker opens. The
-- cursor no longer auto-previews on move — the user explicitly hits
-- <Space> to load the theme under the cursor, and <CR> to commit.
-- Closing the picker without committing restores the snapshot.
--
local Loader = require('atelier.loader')

local M = {}

---@class atelier.Preview
---@field state atelier.State
---@field snapshot string|nil       :colorscheme value at picker-open time.
---@field snapshot_background 'dark'|'light'  vim.o.background at picker-open time.
---@field committed boolean         True once the user pressed <CR>.
---@field previewed_key string|nil  spec_name|theme of the last previewed row.
local Preview = {}
Preview.__index = Preview

---@param state atelier.State
---@return atelier.Preview
function M.new(state)
  local self = setmetatable({
    state = state,
    snapshot = vim.g.colors_name,
    snapshot_background = vim.o.background,
    committed = false,
    previewed_key = nil,
  }, Preview)
  return self
end

---Synchronously load the theme under the cursor as a preview. No debounce,
---no on_load hook. Called from the <Space> keybind.
---@param row atelier.PickerRow|nil
---@return boolean
function Preview:preview_now(row)
  if not row or row.kind ~= 'theme' or not row.rt then return false end
  if row.rt.status ~= 'installed' then return false end

  local key = row.spec_name .. '|' .. row.theme
  if key == self.previewed_key then return false end
  self.previewed_key = key

  local ok = Loader.load(row.rt.spec, row.theme, nil)
  return ok
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
