-- Thin async wrapper around vim.system for the git operations atelier needs.
-- Each function takes an `on_done(result)` callback so jobs.lua can drive
-- them from a worker pool. Completions run on Neovim's main loop.
--
---@class atelier.GitResult
---@field ok boolean
---@field code integer
---@field stdout string
---@field stderr string
---@field cmd string[]

local M = {}

---@param cmd string[]
---@param opts { cwd?: string }|nil
---@param on_done fun(result: atelier.GitResult)
function M.run(cmd, opts, on_done)
  opts = opts or {}

  -- Collect stdout/stderr for the caller. vim.system invokes this callback
  -- in a fast event, so any continuation that touches Neovim state must be
  -- scheduled before it runs.
  local sysopts = {
    cwd = opts.cwd,
    text = true,
  }

  vim.system(cmd, sysopts, function(obj)
    ---@type atelier.GitResult
    local result = {
      ok = obj.code == 0,
      code = obj.code or -1,
      stdout = obj.stdout or '',
      stderr = obj.stderr or '',
      cmd = cmd,
    }
    vim.schedule(function() on_done(result) end)
  end)
end

---@param url string
---@param dest string
---@param opts { branch?: string }|nil
---@param on_done fun(result: atelier.GitResult)
function M.clone(url, dest, opts, on_done)
  opts = opts or {}
  local cmd = { 'git', 'clone', '--depth=1', '--single-branch' }
  if opts.branch then
    cmd[#cmd + 1] = '--branch'
    cmd[#cmd + 1] = opts.branch
  end
  cmd[#cmd + 1] = url
  cmd[#cmd + 1] = dest
  M.run(cmd, nil, on_done)
end

---@param dir string
---@param on_done fun(result: atelier.GitResult)
function M.fetch(dir, on_done)
  M.run({ 'git', 'fetch', '--quiet', 'origin' }, { cwd = dir }, on_done)
end

---@param dir string
---@param on_done fun(result: atelier.GitResult)
function M.pull(dir, on_done)
  M.run({ 'git', 'pull', '--ff-only', '--quiet' }, { cwd = dir }, on_done)
end

---@param dir string
---@param ref string
---@param on_done fun(result: atelier.GitResult)
function M.checkout(dir, ref, on_done)
  M.run({ 'git', 'checkout', '--quiet', ref }, { cwd = dir }, on_done)
end

---@param dir string
---@param ref string
---@param on_done fun(result: atelier.GitResult)
function M.rev_parse(dir, ref, on_done)
  M.run({ 'git', 'rev-parse', ref }, { cwd = dir }, on_done)
end

return M
