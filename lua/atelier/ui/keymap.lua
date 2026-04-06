-- Buffer-local keymaps for the picker. Maps each key to an action function;
-- actions live here so they can be overridden later if we ever expose a
-- "keys = {}" config option. For now they're hardcoded.
--
local Manager = require('atelier.manager')

local M = {}

---@param window atelier.Window  (returned by ui.window.open)
---@param preview atelier.Preview
function M.attach(window, preview)
  local function map(key, fn, desc)
    vim.keymap.set('n', key, fn, { buffer = window.buf, nowait = true, silent = true, desc = desc })
  end

  map('q', function() window:close() end, 'atelier: close')
  map('<Esc>', function() window:close() end, 'atelier: close')

  map('<CR>', function()
    if preview:commit(window:current_row()) then
      window:close()
    end
  end, 'atelier: select')

  map('I', function()
    Manager.install_missing(window.state)
  end, 'atelier: install missing')

  map('U', function()
    Manager.update_all(window.state)
  end, 'atelier: update all')

  map('C', function()
    Manager.clean(window.state)
  end, 'atelier: clean unused')

  map('R', function() window:render() end, 'atelier: redraw')
end

return M
