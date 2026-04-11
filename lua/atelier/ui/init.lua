-- :Atelier entry. Wires window + preview + keymap + initial render.
--
local Window = require('atelier.ui.window')
local Preview = require('atelier.ui.preview')
local Keymap = require('atelier.ui.keymap')
local Highlights = require('atelier.ui.highlights')
local Manager = require('atelier.manager')
local State = require('atelier.state')

local M = {}

---@param state atelier.State
function M.open(state)
  Highlights.setup()
  Manager.refresh_status(state)
  State.reset_ui(state) -- clear stale filter/mode from a prior session

  local window = Window.open(state)
  local preview = Preview.new(state)

  -- Cursor movement no longer auto-previews (the user hits <Space> to
  -- preview explicitly). The info row below the list still re-renders
  -- on cursor move — that's handled inside window:render() via the
  -- hovered_row lookup.
  window.on_cursor = function(row) window:refresh_info(row) end
  window.on_close = function() preview:cleanup() end

  Keymap.attach(window, preview)
  window:render()

  -- Place cursor on the current theme if there is one; otherwise land on
  -- the first selectable row.
  local function place_cursor()
    if state.current.theme then
      for i, row in ipairs(window.rows) do
        if row.kind == 'theme' and row.theme == state.current.theme then
          pcall(vim.api.nvim_win_set_cursor, window.win, { i, 2 })
          return true
        end
      end
    end
    for i, row in ipairs(window.rows) do
      if row.kind == 'theme' or row.kind == 'spec_header' then
        pcall(vim.api.nvim_win_set_cursor, window.win, { i, 2 })
        return true
      end
    end
    return false
  end

  -- If the current theme's spec is collapsed, expand it so the cursor can
  -- land on the actual variant rather than the header.
  if state.current.spec_name then
    local rt = state.by_name[state.current.spec_name]
    if rt then
      rt.expanded = true
      window:render()
    end
  end
  place_cursor()
end

return M
