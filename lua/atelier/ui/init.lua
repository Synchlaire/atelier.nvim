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
  -- Reopening replaces the previous workshop (restores its snapshot first).
  local previous = Window.get()
  if previous then previous:close() end

  Highlights.setup()
  Manager.refresh_status(state)
  State.reset_ui(state) -- clear stale filter/mode from a prior session

  -- Open the active collection before sizing the workshop window.
  if state.current.spec_name then
    local rt = state.by_name[state.current.spec_name]
    if rt then rt.expanded = true end
  end

  local window = Window.open(state)
  local preview
  local ok, err = xpcall(function()

    -- Cursor movement no longer auto-previews (the user hits <Space> to
    -- preview explicitly). The info row below the list still re-renders
    -- on cursor move — that's handled inside window:render() via the
    -- hovered_row lookup.
    window.on_cursor = function(row) window:refresh_info(row) end
    -- Set before anything else can fail so closing the window always runs cleanup.
    window.on_close = function()
      local p = preview or state.preview
      if p then p:cleanup() end
    end
    preview = Preview.new(state)

    -- Light/Dark/Auto controls report through this callback; the preview owns
    -- the draft. Keymap.attach may replace it.
    window.on_mode = function(mode)
      if type(preview.set_mode) ~= 'function' then
        state.ui.message = 'Mode preview is not available yet.'
        return false
      end
      return preview:set_mode(mode)
    end

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
    place_cursor()
  end, tostring)
  if not ok then
    -- Closing runs on_close -> preview cleanup (restores the snapshot and
    -- releases state.preview). Fall back to cleaning up directly if the
    -- window is already gone or never reached on_close.
    pcall(window.close, window)
    local leftover = preview or state.preview
    if leftover and state.preview == leftover then pcall(leftover.cleanup, leftover) end
    state.ui.previewed = nil
    error('atelier: could not open the picker: ' .. tostring(err), 0)
  end
end

return M
