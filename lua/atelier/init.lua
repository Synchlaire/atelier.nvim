-- setup() restores only the active provider before the first editor render.
-- The picker, other providers and desktop transport remain demand-loaded.
local Config = require('atelier.config')
local State = require('atelier.state')
local Api = require('atelier.api')
local M = {}

function M.setup(user)
  local config = Config.normalize(user)
  local state = State.new(config)
  Api._bind(state)

  if config.persist then
    local persisted = require('atelier.persist').read(config.data_dir)
    if persisted.spec_name then
      local Selection = require('atelier.selection')
      local mode = persisted.mode or config.mode
      local rt = state.by_name[persisted.spec_name]
      local choice = persisted.choice or persisted.theme
      -- Legacy background was also saved from metadata, not just a user
      -- toggle. Only an undeclared/different value denotes an override.
      if not persisted.mode and persisted.background and rt
        and require('atelier.loader').declared_background(rt.spec, choice or rt.spec.name) ~= persisted.background then
        mode = persisted.background
      end
      local ok, result = Selection.load(state, persisted.spec_name, choice, {
        mode = mode, strict_mode = persisted.mode ~= nil, background = persisted.background,
      })
      if ok then
        Selection.commit(state, result, false)
      else
        -- Preserve the user's existing scheme and the saved state on disk.
        local message = 'Could not restore selection: ' .. tostring(result)
        state.ui.message = message
        vim.schedule(function() vim.notify('[atelier] ' .. message, vim.log.levels.WARN) end)
      end
    end
  end

  if config.install_on_setup then
    vim.schedule(function()
      if Api._state() == state then
        require('atelier.manager').install_missing(state)
      end
    end)
  end
end

for k, v in pairs(Api) do
  if k:sub(1, 1) ~= '_' then M[k] = v end
end

return M
