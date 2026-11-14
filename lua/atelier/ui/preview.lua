-- Reversible selection transaction shared by the built-in and Snacks UIs.
local Selection = require('atelier.selection')
local M = {}
local Preview = {}
Preview.__index = Preview

function M.new(state)
  local self = setmetatable({
    state = state,
    snapshot = vim.g.colors_name,
    snapshot_background = vim.o.background,
    mode = state.current.mode or state.config.mode or 'auto',
    committed = false,
    previewed_key = nil,
  }, Preview)
  state.preview = self
  require('atelier.appearance').reconcile(state)
  return self
end

function Preview:preview_now(row)
  if not row or row.kind ~= 'theme' or not row.rt then return false end
  return self:preview_item(row)
end

function Preview:preview_item(item, options)
  if self.closed then return false end
  options = options or {}
  local choice = options.strict_mode and item.choice or item.theme
  choice = choice or item.theme
  local key = item.spec_name .. '|' .. choice .. '|' .. self.mode .. '|' .. tostring(options.strict_mode)
  if key == self.previewed_key then return true end
  local ok, result = Selection.load(self.state, item.spec_name, choice, {
    mode = self.mode, strict_mode = options.strict_mode,
    background = self.snapshot_background, hooks = false,
  })
  if not ok then
    self.state.ui.message = 'Preview failed: ' .. tostring(result)
    self.state.bus:emit('state_changed')
    return false
  end
  self.previewed_key = key
  self.mode = result.mode
  self.state.ui.previewed = result
  self.state.ui.message = nil
  require('atelier.appearance').reconcile(self.state)
  self.state.bus:emit('state_changed')
  return true
end

---A mode click/key previews; it does not persist until Enter.
function Preview:set_mode(mode)
  if mode ~= 'auto' and mode ~= 'dark' and mode ~= 'light' then return false end
  local active = self.state.ui.previewed or self.state.current
  if not active.spec_name then
    self.state.ui.message = 'Preview a theme before choosing its mode.'
    self.state.bus:emit('state_changed')
    return false
  end
  local previous_mode, previous_key = self.mode, self.previewed_key
  self.mode = mode
  self.previewed_key = nil
  if self:preview_item(active, { strict_mode = true }) then return true end
  self.mode, self.previewed_key = previous_mode, previous_key
  return false
end

function Preview:commit(row)
  if not row or row.kind ~= 'theme' or not row.rt then return false end
  return self:commit_item(row)
end

function Preview:commit_item(item)
  if self.closed then return false end
  local draft = self.state.ui.previewed or self.state.current
  local applying_draft = draft and draft.spec_name == item.spec_name
    and (item.theme == draft.choice or item.theme == draft.theme)
  local choice = applying_draft and (draft.choice or draft.theme) or item.theme
  local ok, result = Selection.load(self.state, item.spec_name, choice, {
    mode = self.mode, strict_mode = applying_draft,
    background = draft and draft.background or self.snapshot_background,
  })
  if not ok then
    self.state.ui.message = 'Apply failed: ' .. tostring(result)
    self.state.bus:emit('state_changed')
    return false
  end
  self.committed = true
  self.state.ui.message = ('Applied %s · %s%s.'):format(result.theme, result.mode,
    self.state.config.persist and ' · saved' or '')
  Selection.commit(self.state, result)
  return true
end

function Preview:cleanup()
  if self.closed then return end
  self.closed = true
  self.state.ui.previewed = nil
  if not self.committed and (vim.g.colors_name ~= self.snapshot or vim.o.background ~= self.snapshot_background) then
    Selection.restore(self.state, { theme = self.snapshot, background = self.snapshot_background })
  end
  if self.state.preview == self then self.state.preview = nil end
  local Appearance = require('atelier.appearance')
  Appearance.reconcile(self.state)
  Appearance.sync(self.state)
end

function Preview:refresh_auto()
  local draft = self.state.ui.previewed
  if not draft or self.mode ~= 'auto' then return end
  self.previewed_key = nil
  self:preview_item(draft, { strict_mode = true })
end

function Preview:visual_snapshot()
  return {
    theme = vim.g.colors_name,
    background = vim.o.background,
    previewed = vim.deepcopy(self.state.ui.previewed),
    key = self.previewed_key,
    mode = self.mode,
  }
end

function Preview:restore_visual(snapshot)
  if self.closed then return end
  Selection.restore(self.state, snapshot)
  self.state.ui.previewed = snapshot.previewed
  self.previewed_key = snapshot.key
  self.mode = snapshot.mode
  require('atelier.appearance').reconcile(self.state)
  self.state.bus:emit('state_changed')
end

return M
