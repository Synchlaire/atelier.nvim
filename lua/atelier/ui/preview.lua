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
  return self:preview_item({
    spec_name = row.spec_name,
    theme = row.theme,
    rt = row.rt,
  })
end

---@param item { spec_name: string, theme: string, rt: atelier.ThemeRuntime }
---@return boolean
function Preview:preview_item(item)
  if item.rt.status ~= 'installed' then
    self.state.ui.message = item.rt.status == 'failed'
      and ('Cannot preview %s — update or retry first.'):format(item.theme)
      or ('%s is not installed — press I to install.'):format(item.theme)
    self.state.bus:emit('state_changed')
    return false
  end

  local key = item.spec_name .. '|' .. item.theme
  if key == self.previewed_key then return false end

  local ok, err = Loader.load(item.rt.spec, item.theme, nil)
  if not ok then
    self.state.ui.message = ('Preview failed: %s'):format(tostring(err))
    self.state.bus:emit('state_changed')
    return false
  end

  self.previewed_key = key
  self.state.ui.previewed = {
    spec_name = item.spec_name,
    theme = item.theme,
    background = vim.o.background,
  }
  self.state.ui.message = nil
  self.state.bus:emit('state_changed')
  return ok
end

---Commit the currently-previewed theme as the active one. Persists.
---@param row atelier.PickerRow|nil
---@return boolean
function Preview:commit(row)
  if not row or row.kind ~= 'theme' or not row.rt then return false end
  return self:commit_item({
    spec_name = row.spec_name,
    theme = row.theme,
    rt = row.rt,
  })
end

---@param item { spec_name: string, theme: string, rt: atelier.ThemeRuntime }
---@return boolean
function Preview:commit_item(item)
  if item.rt.status ~= 'installed' then
    self.state.ui.message = ('%s is not installed — press I to install.'):format(item.theme)
    self.state.bus:emit('state_changed')
    return false
  end

  local ok, err = Loader.load(item.rt.spec, item.theme, self.state.config.on_load)
  if not ok then
    self.state.ui.message = ('Apply failed: %s'):format(tostring(err))
    self.state.bus:emit('state_changed')
    return false
  end

  -- Capture vim.o.background only when something declared an opinion —
  -- either the spec or a prior `B` toggle that changed it away from the
  -- snapshot. nil means "atelier had no opinion, leave it alone".
  local bg = nil
  if Loader.declared_background(item.rt.spec, item.theme)
    or vim.o.background ~= self.snapshot_background then
    bg = vim.o.background
  end

  self.state.current = { spec_name = item.spec_name, theme = item.theme, background = bg }
  self.state.last_good = vim.deepcopy(self.state.current)
  self.committed = true
  self.state.ui.previewed = nil
  self.state.ui.message = ('Applied %s · saved to the bench.'):format(item.theme)
  if self.state.config.persist then
    require('atelier.persist').write(self.state.config.data_dir, self.state.current)
  end
  self.state.bus:emit('state_changed')
  return true
end

---Restore the snapshot if nothing was committed. Called from on_close.
function Preview:cleanup()
  self.state.ui.previewed = nil
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

---@return { theme: string|nil, background: 'dark'|'light', previewed: atelier.Current|nil, key: string|nil }
function Preview:visual_snapshot()
  return {
    theme = vim.g.colors_name,
    background = vim.o.background,
    previewed = vim.deepcopy(self.state.ui.previewed),
    key = self.previewed_key,
  }
end

---@param snapshot { theme: string|nil, background: 'dark'|'light', previewed: atelier.Current|nil, key: string|nil }
function Preview:restore_visual(snapshot)
  vim.o.background = snapshot.background
  if snapshot.theme and vim.g.colors_name ~= snapshot.theme then
    pcall(vim.cmd.colorscheme, snapshot.theme)
  end
  self.state.ui.previewed = snapshot.previewed
  self.previewed_key = snapshot.key
  self.state.bus:emit('state_changed')
end

return M
