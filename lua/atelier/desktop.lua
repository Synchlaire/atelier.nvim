-- Linux desktop appearance provider (xdg-desktop-portal color-scheme).
-- Nothing runs until M.start() is called.
local M = {}

local DEST = 'org.freedesktop.portal.Desktop'
local PATH = '/org/freedesktop/portal/desktop'
local IFACE = 'org.freedesktop.portal.Settings'
local NAMESPACE = 'org.freedesktop.appearance'
local KEY = 'color-scheme'
local READ_TIMEOUT = 2000
local MAX_BUFFER = 64 * 1024

-- 1 = prefer dark, 2 = prefer light, 0 = no preference, anything else unknown.
local function map_scheme(value)
  if value == 1 then
    return 'dark'
  elseif value == 2 then
    return 'light'
  end
end

-- The uint32 marker is the only relevant part of gdbus output, e.g.
-- "(<<uint32 1>>,)", "(<uint32 1>,)" or a SettingChanged signal line.
function M.parse(text)
  local n = tostring(text or ''):match('uint32%s+(%d+)')
  return n and tonumber(n) or nil
end

local function is_signal(line)
  return line:find('SettingChanged', 1, true) and line:find(NAMESPACE, 1, true) and line:find(KEY, 1, true)
end

local function parse_signal(line)
  if is_signal(line) then
    local _, e = line:find(KEY, 1, true)
    return M.parse(line:sub(e + 1))
  end
end

local function noop() end

function M.start(opts, callback)
  if type(opts) == 'function' then
    opts, callback = nil, opts
  end
  opts = opts or {}
  callback = callback or noop

  local stopped = false
  local function emit(scheme, err)
    vim.schedule(function()
      if not stopped then
        callback(scheme, err)
      end
    end)
  end

  local stop_hooks = {}
  local leave_id
  local function stop()
    if stopped then
      return
    end
    stopped = true
    if leave_id then
      pcall(vim.api.nvim_del_autocmd, leave_id)
    end
    for _, hook in ipairs(stop_hooks) do
      pcall(hook)
    end
    stop_hooks = {}
  end
  local function register_leave()
    leave_id = vim.api.nvim_create_autocmd('VimLeavePre', { once = true, callback = stop })
  end

  -- Custom provider: opts.provider.start (or opts.start for compatibility).
  local provider = type(opts.provider) == 'table' and opts.provider or opts
  if type(provider.start) == 'function' then
    register_leave()
    local ok, res = pcall(provider.start, function(scheme, err)
      if scheme ~= 'dark' and scheme ~= 'light' then
        scheme = nil
      end
      emit(scheme, err)
    end)
    if ok then
      if type(res) == 'function' then
        stop_hooks[#stop_hooks + 1] = res
      end
    else
      emit(nil, tostring(res))
    end
    return stop
  end

  local sysname = opts.sysname or (vim.uv or vim.loop).os_uname().sysname
  if sysname ~= 'Linux' then
    emit(nil)
    return function()
      stopped = true
    end
  end
  local executable = opts.executable or function(name)
    return vim.fn.executable(name) == 1
  end
  if not executable('gdbus') then
    emit(nil, 'gdbus not available')
    return function()
      stopped = true
    end
  end

  local system = opts.system or vim.system
  local procs = {}
  local seen_signal = false

  local function spawn(cmd, sysopts, on_exit)
    local ok, proc = pcall(system, cmd, sysopts, on_exit)
    if not ok then
      return nil, tostring(proc)
    end
    procs[#procs + 1] = proc
    return proc
  end

  stop_hooks[#stop_hooks + 1] = function()
    for _, proc in ipairs(procs) do
      pcall(proc.kill, proc, 15)
    end
    procs = {}
  end
  register_leave()

  local function read(method, on_fail)
    local _, err = spawn({ 'gdbus', 'call', '--session', '--dest', DEST, '--object-path', PATH, '--method', IFACE .. '.' .. method, NAMESPACE, KEY }, {
      text = true,
      timeout = opts.timeout or READ_TIMEOUT,
    }, function(res)
      vim.schedule(function()
        if stopped or seen_signal then
          return -- a newer signal value already won
        end
        local value = res.code == 0 and M.parse(res.stdout) or nil
        if value ~= nil then
          callback(map_scheme(value))
        elseif method == 'ReadOne' then
          read('Read')
        else
          callback(nil, 'could not read color-scheme')
        end
      end)
    end)
    if err then
      emit(nil, err)
    end
  end

  -- Monitor first so no change is missed while the initial read is in flight.
  local buffer = ''
  local function on_stdout(err, data)
    if err or not data or stopped then
      return
    end
    buffer = buffer .. data
    while true do
      local nl = buffer:find('\n', 1, true)
      if not nl then
        break
      end
      local line = buffer:sub(1, nl - 1)
      buffer = buffer:sub(nl + 1)
      local value = parse_signal(line)
      if is_signal(line) then
        seen_signal = true
        emit(map_scheme(value))
      end
    end
    if #buffer > MAX_BUFFER then
      buffer = '' -- runaway line without newline: drop it
    end
  end

  local _, merr = spawn(
    { 'gdbus', 'monitor', '--session', '--dest', DEST, '--object-path', PATH },
    { text = true, stdout = on_stdout },
    function(res)
      if not stopped and res.code ~= 0 and res.signal == 0 then
        vim.schedule(function()
          if not stopped then
            callback(nil, 'gdbus monitor exited')
          end
        end)
      end
    end
  )
  if merr then
    emit(nil, merr)
  end
  read('ReadOne')

  return stop
end

return M
