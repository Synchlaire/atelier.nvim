-- :Atelier entry. Wires window + preview + keymap + initial render.
--
local Window = require('atelier.ui.window')
local Preview = require('atelier.ui.preview')
local Keymap = require('atelier.ui.keymap')
local Highlights = require('atelier.ui.highlights')
local Manager = require('atelier.manager')

local M = {}

---@param state atelier.State
function M.open(state)
  Highlights.setup()
  Manager.refresh_status(state)

  local window = Window.open(state)
  local preview = Preview.new(state)

  window.on_cursor = function(row) preview:on_cursor(row) end
  window.on_close = function() preview:cleanup() end

  Keymap.attach(window, preview)
  window:render()

  -- Place cursor on the current theme if there is one, otherwise on the
  -- first selectable row.
  for i, row in ipairs(window.rows) do
    if row.kind == 'theme' then
      if state.current.theme and row.theme == state.current.theme then
        pcall(vim.api.nvim_win_set_cursor, window.win, { i, 2 })
        return
      end
    end
  end
  for i, row in ipairs(window.rows) do
    if row.kind == 'theme' then
      pcall(vim.api.nvim_win_set_cursor, window.win, { i, 2 })
      return
    end
  end
end

return M
