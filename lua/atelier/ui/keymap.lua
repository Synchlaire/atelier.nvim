-- Buffer-local keymaps for the picker. Maps each key to an action function;
-- actions are kept here so they can be overridden later if we ever expose a
-- `keys = {}` config option. For now they're hardcoded.
--
local Manager = require('atelier.manager')
local Picker = require('atelier.ui.picker')
local Filter = require('atelier.ui.filter')

local M = {}

---@param window atelier.Window
---@param preview atelier.Preview
function M.attach(window, preview)
  local function map(key, fn, desc)
    vim.keymap.set('n', key, fn, { buffer = window.buf, nowait = true, silent = true, desc = desc })
  end

  map('q', function() window:close() end, 'atelier: close')
  map('<Esc>', function()
    -- If a filter is active, <Esc> clears it instead of closing the picker.
    if window.state.ui.filter ~= '' then
      window.state.ui.filter = ''
      window:render()
    else
      window:close()
    end
  end, 'atelier: close / clear filter')

  -- <CR> on a theme commits & closes; on a spec header it toggles the fold.
  map('<CR>', function()
    local row = window:current_row()
    if not row then return end
    if row.kind == 'spec_header' and row.spec_name then
      Picker.toggle_fold(window.state, row.spec_name)
      return
    end
    if preview:commit(row) then
      window:close()
    end
  end, 'atelier: select / toggle fold')

  -- Tab also toggles the fold under the cursor; works on either a header
  -- row or a variant row inside a group.
  map('<Tab>', function()
    local row = window:current_row()
    if not row or not row.spec_name then return end
    Picker.toggle_fold(window.state, row.spec_name)
  end, 'atelier: toggle fold')

  -- Vim-style fold-all / unfold-all.
  map('zM', function() Picker.set_all_folds(window.state, false) end, 'atelier: collapse all')
  map('zR', function() Picker.set_all_folds(window.state, true) end, 'atelier: expand all')
  map('zc', function()
    local row = window:current_row()
    if row and row.spec_name then
      local rt = window.state.by_name[row.spec_name]
      if rt and rt.expanded then Picker.toggle_fold(window.state, row.spec_name) end
    end
  end, 'atelier: close fold')
  map('zo', function()
    local row = window:current_row()
    if row and row.spec_name then
      local rt = window.state.by_name[row.spec_name]
      if rt and not rt.expanded then Picker.toggle_fold(window.state, row.spec_name) end
    end
  end, 'atelier: open fold')

  -- Inline filter (always available).
  map('/', function()
    Filter.run(window.state, window)
  end, 'atelier: filter')

  -- Snacks.picker handoff if available; falls back to inline filter.
  local function snacks_open()
    require('atelier.ui.snacks').open(window, function() window:close() end)
  end
  map('<C-/>', snacks_open, 'atelier: snacks search')
  map('<C-_>', snacks_open, 'atelier: snacks search') -- terminal alias

  map('I', function() Manager.install_missing(window.state) end, 'atelier: install missing')
  map('U', function() Manager.update_all(window.state) end, 'atelier: update all')
  map('C', function() Manager.clean(window.state) end, 'atelier: clean unused')
  map('R', function() window:render() end, 'atelier: redraw')
end

return M
