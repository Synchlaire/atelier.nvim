-- Optional snacks.picker handoff. If snacks is installed, the picker offers
-- a `<C-/>` shortcut to fuzzy-find themes through snacks's UI. If it isn't,
-- this module silently falls back to inline filter mode.
--
-- We never `require('snacks')` at module-load time — the require happens
-- inside `open()` so atelier has zero hard dependency on snacks.
--
local M = {}

---@param state atelier.State
---@return { name: string, spec_name: string, theme: string, rt: atelier.ThemeRuntime }[]
local function build_items(state)
  local Manager = require('atelier.manager')
  local items = {}
  for _, rt in ipairs(state.themes) do
    local variants = Manager.discover(state, rt)
    local theme_list = (#variants > 0) and variants or { rt.spec.name }
    for _, theme in ipairs(theme_list) do
      items[#items + 1] = {
        text = theme .. ' (' .. rt.spec.name .. ')',
        spec_name = rt.spec.name,
        theme = theme,
        rt = rt,
      }
    end
  end
  return items
end

---Open snacks.picker if available; falls back to inline filter otherwise.
---@param window atelier.Window
---@param close_picker fun()|nil  Called after a successful selection so the
---                               atelier window can close behind the snacks UI.
function M.open(window, close_picker)
  local state = window.state
  local ok, snacks = pcall(require, 'snacks')
  if not ok or not snacks.picker then
    -- Graceful fallback: just enter inline filter mode in the existing picker.
    require('atelier.ui.filter').run(state, window)
    return
  end

  local items = build_items(state)
  local Loader = require('atelier.loader')
  local Persist = require('atelier.persist')

  snacks.picker.pick({
    source = 'atelier',
    title = 'atelier themes',
    items = items,
    format = function(item)
      return {
        { item.theme, 'AtelierTheme' },
        { '  ', 'Normal' },
        { '(' .. item.spec_name .. ')', 'AtelierSubtle' },
      }
    end,
    -- Live preview as the user moves through results.
    preview = function(ctx)
      local item = ctx.item
      if item and item.rt and item.rt.status == 'installed' then
        pcall(Loader.load, item.rt.spec, item.theme, nil)
      end
      return false -- we don't render anything in the preview pane
    end,
    confirm = function(picker, item)
      picker:close()
      if not item or not item.rt or item.rt.status ~= 'installed' then return end
      local ok2, err = Loader.load(item.rt.spec, item.theme, state.config.on_load)
      if not ok2 then
        vim.notify('[atelier] ' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      state.current = { spec_name = item.spec_name, theme = item.theme }
      state.last_good = state.current
      if state.config.persist then
        Persist.write(state.config.data_dir, state.current)
      end
      state.bus:emit('state_changed')
      if close_picker then close_picker() end
    end,
  })
end

return M
