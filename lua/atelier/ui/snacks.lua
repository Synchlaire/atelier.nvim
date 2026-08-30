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
---@param preview atelier.Preview
function M.open(window, preview)
  local state = window.state
  local ok, snacks = pcall(require, 'snacks')
  if not ok or not snacks.picker then
    -- Graceful fallback: just enter inline filter mode in the existing picker.
    require('atelier.ui.filter').run(state, window)
    return
  end

  local items = build_items(state)
  local handoff = preview:visual_snapshot()
  local confirmed = false

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
    -- Live preview as the user moves through results. The built-in picker
    -- previews explicitly with <Space>; Snacks owns its own cursor-driven UI.
    preview = function(ctx)
      local item = ctx.item
      if item and item.rt and item.rt.status == 'installed' then
        preview:preview_item(item)
      end
      return false -- we don't render anything in the preview pane
    end,
    confirm = function(picker, item)
      if not item or not item.rt or item.rt.status ~= 'installed' then
        return
      end
      if preview:commit_item(item) then
        confirmed = true
        picker:close()
        window:close()
      end
    end,
    on_close = function()
      if not confirmed then
        preview:restore_visual(handoff)
      end
    end,
  })
end

return M
