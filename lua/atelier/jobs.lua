-- Bounded worker pool. Submit a list of jobs; up to N run concurrently.
-- Each job is a function (on_done) -> nil that MUST eventually call on_done.
-- The pool reports progress through a callback so the caller can map jobs
-- back to themes and emit picker-update events.
--
---@class atelier.JobSpec
---@field key string                                  Stable id (theme name) so callers can correlate events.
---@field run fun(on_done: fun(ok: boolean, info: any))  Job body. Must call on_done exactly once.

---@class atelier.PoolHandle
---@field cancel fun()                                Stops dispatching new jobs; in-flight ones still finish.
---@field active fun(): integer                       Number of jobs currently running.
---@field pending fun(): integer                      Number of jobs queued but not yet started.

local M = {}

---@param jobs atelier.JobSpec[]
---@param parallel integer
---@param callbacks { on_start?: fun(key: string), on_done: fun(key: string, ok: boolean, info: any), on_finished?: fun() }
---@return atelier.PoolHandle
function M.run(jobs, parallel, callbacks)
  local queue = {}
  for i, j in ipairs(jobs) do queue[i] = j end

  local index = 1
  local active = 0
  local cancelled = false
  local total = #jobs
  local completed = 0

  local function dispatch()
    if cancelled then
      if active == 0 and callbacks.on_finished then callbacks.on_finished() end
      return
    end
    while active < parallel and index <= #queue do
      local job = queue[index]
      index = index + 1
      active = active + 1
      if callbacks.on_start then callbacks.on_start(job.key) end

      -- Wrap on_done so the slot is freed and the next job is dispatched
      -- exactly once even if the job body is buggy and double-fires.
      local fired = false
      job.run(function(ok, info)
        if fired then return end
        fired = true
        active = active - 1
        completed = completed + 1
        callbacks.on_done(job.key, ok, info)
        if completed >= total and active == 0 then
          if callbacks.on_finished then callbacks.on_finished() end
        else
          dispatch()
        end
      end)
    end
  end

  -- If there's nothing to do, fire on_finished synchronously on next tick
  -- so callers can attach UI updates uniformly.
  if total == 0 then
    if callbacks.on_finished then
      vim.schedule(callbacks.on_finished)
    end
  else
    dispatch()
  end

  return {
    cancel = function() cancelled = true end,
    active = function() return active end,
    pending = function() return math.max(0, #queue - index + 1) end,
  }
end

return M
