-- Host events never change the user's mode or variant anchor. While a
-- transaction is open they can refresh an Auto draft, never the committed
-- selection. After closing, the committed Auto selection catches up.
local M = {}

function M.stop(state)
  local desktop = state.desktop
  if not desktop then return end
  desktop.generation = (desktop.generation or 0) + 1
  if desktop.stop then pcall(desktop.stop) end
  desktop.stop = nil
  desktop.following = false
  desktop.background = nil
end

function M.sync(state)
  local desktop = state.desktop
  if not desktop or not desktop.following or state.preview then return end
  local current = state.current
  if not current.spec_name or current.mode ~= 'auto' then return end
  if not desktop.background or desktop.background == current.background then return end
  local Selection = require('atelier.selection')
  local ok, result = Selection.load(state, current.spec_name, current.choice or current.theme, {
    mode = 'auto', strict_mode = true, background = current.background,
  })
  if ok then
    state.current = result
    state.last_good = vim.deepcopy(result)
    -- Cache the last effective result so tomorrow's startup does not keep
    -- flashing the background saved at the original commit. Preference and
    -- anchor are unchanged; a preview never reaches this write path.
    Selection.cache(state, result)
  else
    state.ui.message = 'Desktop theme change failed: ' .. tostring(result)
  end
  state.bus:emit('state_changed')
end

local function follows(state, selection, mode)
  local rt = selection and state.by_name[selection.spec_name]
  return mode == 'auto' and rt and require('atelier.selection').supports_auto(rt.spec)
end

function M.reconcile(state)
  state.desktop = state.desktop or { background = nil }
  local desktop = state.desktop
  local preview = state.preview
  local draft = state.ui.previewed or state.current
  local needed = follows(state, state.current, state.current.mode)
    or (preview and follows(state, draft, preview.mode))
  if not needed then
    M.stop(state)
    return
  end
  if desktop.following then return end
  desktop.following = true
  desktop.generation = (desktop.generation or 0) + 1
  local generation = desktop.generation
  local function changed(background, err)
    if generation ~= desktop.generation then return end
    if err then
      state.ui.message = 'Auto unavailable; keeping ' .. (vim.o.background) .. ': ' .. tostring(err)
      state.bus:emit('state_changed')
    end
    if desktop.background == background then return end
    desktop.background = background
    local transaction = state.preview
    if transaction then
      if transaction.mode == 'auto' and state.ui.previewed then transaction:refresh_auto() end
    else
      M.sync(state)
    end
  end
  desktop.stop = require('atelier.desktop').start({ provider = state.config.desktop_provider }, changed)
end

return M
