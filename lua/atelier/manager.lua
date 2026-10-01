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
  for _, path in ipairs(vim.opt.rtp:get()) do
    if path == dir then return end
  end
  vim.opt.rtp:prepend(dir)
end

---Walk all themes and update their `status` field based on disk state.
---Pure inspection — no git, no I/O beyond fs_stat.
---@param state atelier.State
function M.refresh_status(state)
  for _, rt in ipairs(state.themes) do
    if rt.status ~= 'installing' and rt.status ~= 'updating' then
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

local function operation_blocked(state)
  if not state.operation then return false end
  state.ui.message = ('%s already in progress · %d/%d complete.'):format(
    state.operation.kind, state.operation.completed, state.operation.total)
  state.bus:emit('state_changed')
  return true
end

local function begin_operation(state, kind, total)
  state.operation = { kind = kind, completed = 0, total = total, failed = 0 }
  state.ui.message = ('%s started · 0/%d complete.'):format(kind, total)
  state.bus:emit('state_changed')
end

local function complete_job(state, ok)
  if not state.operation then return end
  state.operation.completed = state.operation.completed + 1
  if not ok then state.operation.failed = state.operation.failed + 1 end
  state.bus:emit('state_changed')
end

local function finish_operation(state, event)
  local op = state.operation
  if not op then return end
  local succeeded = op.total - op.failed
  local failure_summary = ''
  if op.failed > 0 then failure_summary = (' · %d failed'):format(op.failed) end
  state.ui.message = ('%s finished · %d ready%s.'):format(op.kind, succeeded, failure_summary)
  state.operation = nil
  state.bus:emit(event, { succeeded = succeeded, failed = op.failed, total = op.total })
  state.bus:emit('state_changed')
end

---Install all themes whose status is 'missing'. Built-ins and existing
---local specs are skipped. Runs jobs in parallel up to config.parallel.
---@param state atelier.State
---@param on_finished fun()|nil
function M.install_missing(state, on_finished)
  if operation_blocked(state) then return end
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
              rt.themes = nil
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

  if #jobs == 0 then
    state.ui.message = 'All configured themes are already on the bench.'
    state.bus:emit('install_finished', { succeeded = 0, failed = 0, total = 0 })
    state.bus:emit('state_changed')
    if on_finished then on_finished() end
    return
  end

  begin_operation(state, 'install', #jobs)

  Jobs.run(jobs, state.config.parallel, {
    on_done = function(_, ok) complete_job(state, ok) end,
    on_finished = function()
      finish_operation(state, 'install_finished')
      if on_finished then on_finished() end
    end,
  })
end

---Update all installed remote themes by fetch + ff-pull. Local and built-in
---themes are skipped.
---@param state atelier.State
---@param on_finished fun()|nil
function M.update_all(state, on_finished)
  if operation_blocked(state) then return end
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
                rt.themes = nil
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

  if #jobs == 0 then
    state.ui.message = 'No installed remote themes need an update pass.'
    state.bus:emit('update_finished', { succeeded = 0, failed = 0, total = 0 })
    state.bus:emit('state_changed')
    if on_finished then on_finished() end
    return
  end

  begin_operation(state, 'update', #jobs)

  Jobs.run(jobs, state.config.parallel, {
    on_done = function(_, ok) complete_job(state, ok) end,
    on_finished = function()
      finish_operation(state, 'update_finished')
      if on_finished then on_finished() end
    end,
  })
end

---List install directories that are no longer represented by the config.
---@param state atelier.State
---@return { name: string, path: string }[]
function M.clean_plan(state)
  local sites_dir = vim.fs.joinpath(state.config.data_dir, 'sites')
  if not dir_exists(sites_dir) then return {} end

  local known = {}
  for _, rt in ipairs(state.themes) do
    if not rt.spec.builtin and not rt.spec.local_path then
      known[rt.spec.name] = true
    end
  end

  local handle = uv.fs_scandir(sites_dir)
  if not handle then return {} end
  local plan = {}
  while true do
    local name, t = uv.fs_scandir_next(handle)
    if not name then break end
    if t == 'directory' and name ~= 'trash' and not known[name] then
      plan[#plan + 1] = { name = name, path = vim.fs.joinpath(sites_dir, name) }
    end
  end
  table.sort(plan, function(a, b) return a.name < b.name end)
  return plan
end

---Move unused theme directories into a recoverable trash directory.
---@param state atelier.State
---@param plan { name: string, path: string }[]|nil
---@return { moved: integer, failed: integer, trash_dir: string|nil }
function M.clean(state, plan)
  plan = plan or M.clean_plan(state)
  if #plan == 0 then
    state.ui.message = 'The bench is already clean.'
    state.bus:emit('clean_finished', { moved = 0, failed = 0 })
    state.bus:emit('state_changed')
    return { moved = 0, failed = 0, trash_dir = nil }
  end

  local sites_dir = vim.fs.joinpath(state.config.data_dir, 'sites')
  local trash_dir = vim.fs.joinpath(sites_dir, 'trash', os.date('%Y%m%d-%H%M%S'))
  vim.fn.mkdir(trash_dir, 'p')
  local moved, failed = 0, 0
  for _, item in ipairs(plan) do
    local destination = vim.fs.joinpath(trash_dir, item.name)
    if uv.fs_rename(item.path, destination) then
      moved = moved + 1
    else
      failed = failed + 1
    end
  end

  local failure_summary = ''
  if failed > 0 then failure_summary = (' · %d failed'):format(failed) end
  state.ui.message = ('Bench cleaned · %d archived%s.'):format(moved, failure_summary)
  local result = { moved = moved, failed = failed, trash_dir = trash_dir }
  state.bus:emit('clean_finished', result)
  state.bus:emit('state_changed')
  return result
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
