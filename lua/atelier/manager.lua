-- Install / update / clean orchestration. Owns directory layout under
-- config.data_dir/sites/<name> and feeds jobs.lua. Mutates state.themes[i]
-- entries and emits 'theme_changed' on the bus when statuses move.
--
local Git = require('atelier.git')
local Jobs = require('atelier.jobs')
local Loader = require('atelier.loader')

local uv = vim.uv or vim.loop
local M = {}

---Absolute directory where a remote spec is cloned. Built-ins and local
---specs return nil — those have nothing to manage.
---@param state atelier.State
---@param spec atelier.ThemeSpec
---@return string|nil
function M.dir_for(state, spec)
  if spec.builtin then return nil end
  if spec.local_path then return spec.local_path end
  return vim.fs.joinpath(state.config.data_dir, 'sites', spec.name)
end

---@param dir string
---@return boolean
local function dir_exists(dir)
  local stat = uv.fs_stat(dir)
  return stat ~= nil and stat.type == 'directory'
end

---Add the install dir to runtimepath so :colorscheme can find it.
---Idempotent.
---@param dir string
local function add_to_rtp(dir)
  if not dir then return end
  -- vim.opt.rtp:prepend deduplicates internally? No — guard manually.
  local current = vim.api.nvim_get_option_value('runtimepath', {})
  if not current:find(dir, 1, true) then
    vim.opt.rtp:prepend(dir)
  end
end

---Walk all themes and update their `status` field based on disk state.
---Pure inspection — no git, no I/O beyond fs_stat.
---@param state atelier.State
function M.refresh_status(state)
  for _, rt in ipairs(state.themes) do
    local dir = M.dir_for(state, rt.spec)
    if rt.spec.builtin then
      rt.status = 'installed'
    elseif rt.spec.local_path then
      rt.status = dir_exists(dir) and 'installed' or 'missing'
      if rt.status == 'installed' then add_to_rtp(dir) end
    else
      if dir_exists(dir) then
        rt.status = 'installed'
        add_to_rtp(dir)
      else
        rt.status = 'missing'
      end
    end
  end
  state.bus:emit('state_changed')
end

---@param rt atelier.ThemeRuntime
---@param status atelier.Status
---@param state atelier.State
local function set_status(rt, status, state, err)
  rt.status = status
  rt.error = err
  state.bus:emit('state_changed')
end

---Install all themes whose status is 'missing'. Built-ins and existing
---local specs are skipped. Runs jobs in parallel up to config.parallel.
---@param state atelier.State
---@param on_finished fun()|nil
function M.install_missing(state, on_finished)
  M.refresh_status(state)

  local jobs = {}
  for _, rt in ipairs(state.themes) do
    if rt.status == 'missing' and rt.spec.url then
      local dest = M.dir_for(state, rt.spec)
      jobs[#jobs + 1] = {
        key = rt.spec.name,
        run = function(done)
          set_status(rt, 'installing', state)
          Git.clone(rt.spec.url, dest, { branch = rt.spec.branch }, function(result)
            if result.ok then
              add_to_rtp(dest)
              set_status(rt, 'installed', state)
              done(true, result)
            else
              local first_line = (result.stderr or ''):match('([^\n]+)') or 'clone failed'
              set_status(rt, 'failed', state, first_line)
              done(false, result)
            end
          end)
        end,
      }
    end
  end

  Jobs.run(jobs, state.config.parallel, {
    on_done = function() end, -- per-job side effects already happen inside `run`
    on_finished = function()
      state.bus:emit('install_finished')
      if on_finished then on_finished() end
    end,
  })
end

---Update all installed remote themes by fetch + ff-pull. Local and built-in
---themes are skipped.
---@param state atelier.State
---@param on_finished fun()|nil
function M.update_all(state, on_finished)
  M.refresh_status(state)

  local jobs = {}
  for _, rt in ipairs(state.themes) do
    if rt.status == 'installed' and rt.spec.url and not rt.spec.local_path then
      local dir = M.dir_for(state, rt.spec)
      jobs[#jobs + 1] = {
        key = rt.spec.name,
        run = function(done)
          set_status(rt, 'updating', state)
          Git.fetch(dir, function(fetch_result)
            if not fetch_result.ok then
              local first = (fetch_result.stderr or ''):match('([^\n]+)') or 'fetch failed'
              set_status(rt, 'failed', state, first)
              return done(false, fetch_result)
            end
            Git.pull(dir, function(pull_result)
              if pull_result.ok then
                set_status(rt, 'installed', state)
                done(true, pull_result)
              else
                local first = (pull_result.stderr or ''):match('([^\n]+)') or 'pull failed'
                set_status(rt, 'failed', state, first)
                done(false, pull_result)
              end
            end)
          end)
        end,
      }
    end
  end

  Jobs.run(jobs, state.config.parallel, {
    on_done = function() end,
    on_finished = function()
      state.bus:emit('update_finished')
      if on_finished then on_finished() end
    end,
  })
end

---Remove install directories for themes that are no longer in the config.
---Only touches subdirs of `<data_dir>/sites/`. Synchronous because removal
---is fast and the safety review is easier when it's serial.
---@param state atelier.State
function M.clean(state)
  local sites_dir = vim.fs.joinpath(state.config.data_dir, 'sites')
  if not dir_exists(sites_dir) then return end

  local known = {}
  for _, rt in ipairs(state.themes) do
    if not rt.spec.builtin and not rt.spec.local_path then
      known[rt.spec.name] = true
    end
  end

  local handle = uv.fs_scandir(sites_dir)
  if not handle then return end
  while true do
    local name, t = uv.fs_scandir_next(handle)
    if not name then break end
    if t == 'directory' and not known[name] then
      vim.fn.delete(vim.fs.joinpath(sites_dir, name), 'rf')
    end
  end

  state.bus:emit('clean_finished')
end

---Discover and cache the theme variants for a runtime entry.
---@param state atelier.State
---@param rt atelier.ThemeRuntime
function M.discover(state, rt)
  if rt.themes then return rt.themes end
  local dir = M.dir_for(state, rt.spec)
  rt.themes = Loader.filter(Loader.discover_themes(dir), rt.spec)
  return rt.themes
end

return M
