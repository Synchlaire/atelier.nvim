-- atelier.nvim entry point. setup() is the only thing that has to be called
-- before anything else; everything else is re-exported from api.lua.
--
local Config = require('atelier.config')
local State = require('atelier.state')
local Api = require('atelier.api')

local M = {}

---@param user table|nil
function M.setup(user)
  local config = Config.normalize(user)
  local state = State.new(config)
  Api._bind(state)

  -- Make the picker discover real status without doing git or scans yet.
  -- This is fs_stat-only and runs synchronously in setup, but it's cheap
  -- (one stat per spec) and we need it before any of the other init steps
  -- can do anything useful.
  require('atelier.manager').refresh_status(state)

  -- Persisted-theme load: defer to VimEnter so we don't fight the user's
  -- config order. If we're already inside the editor (e.g. lazy reload),
  -- run on next tick.
  if config.persist then
    local function load_persisted()
      local persisted = require('atelier.persist').read(config.data_dir)
      if not persisted.spec_name then return end
      local rt = state.by_name[persisted.spec_name]
      if rt and rt.status == 'installed' then
        local Loader = require('atelier.loader')
        local ok = Loader.load(rt.spec, persisted.theme, config.on_load)
        if ok then
          state.current = persisted
          state.last_good = persisted
          state.bus:emit('state_changed')
        end
      end
    end

    if vim.v.vim_did_enter == 1 then
      vim.schedule(load_persisted)
    else
      vim.api.nvim_create_autocmd('VimEnter', {
        once = true,
        callback = load_persisted,
      })
    end
  end

  if config.install_on_setup then
    -- Schedule so it doesn't block startup; the manager already runs git
    -- async, but kicking it off from a scheduled callback keeps setup()
    -- itself a no-op for the main loop.
    vim.schedule(function()
      require('atelier.manager').install_missing(state)
    end)
  end
end

-- Re-export the public API so users don't have to know about api.lua.
for k, v in pairs(Api) do
  if k:sub(1, 1) ~= '_' then M[k] = v end
end

return M
