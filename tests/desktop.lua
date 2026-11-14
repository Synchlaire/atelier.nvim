local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local desktop = require('atelier.desktop')

local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    error(('%s: %s'):format(name, err))
  end
  passed = passed + 1
end
local function eq(a, b)
  assert(vim.deep_equal(a, b), ('expected %s, got %s'):format(vim.inspect(b), vim.inspect(a)))
end
local function flush()
  vim.wait(20)
end

-- Fake vim.system: records calls; tests drive exits and stdout manually.
local function fake()
  local f = { calls = {} }
  f.system = function(cmd, o, on_exit)
    local p = { cmd = cmd, opts = o, on_exit = on_exit, killed = false }
    p.kill = function() p.killed = true end
    f.calls[#f.calls + 1] = p
    return p
  end
  f.opts = function() return { system = f.system, sysname = 'Linux', executable = function() return true end } end
  f.find = function(method)
    for _, p in ipairs(f.calls) do
      if vim.tbl_contains(p.cmd, 'monitor') and method == 'monitor' then return p end
      if p.cmd[9] and p.cmd[9]:find(method .. '$') and p.cmd[2] == 'call' then return p end
    end
  end
  return f
end

local SIGNAL = "/org/freedesktop/portal/desktop: org.freedesktop.portal.Settings.SettingChanged ('org.freedesktop.appearance', 'color-scheme', <uint32 %d>)\n"

test('parse extracts uint32', function()
  eq(desktop.parse('(<<uint32 2>>,)'), 2)
  eq(desktop.parse('(<uint32 1>,)'), 1)
  eq(desktop.parse('garbage'), nil)
end)

test('ReadOne result maps dark/light/unknown', function()
  for out, want in pairs({ ['(<<uint32 1>>,)'] = 'dark', ['(<<uint32 2>>,)'] = 'light', ['(<<uint32 0>>,)'] = 'none', ['(<<uint32 9>>,)'] = 'none' }) do
    local f, got = fake(), {}
    local stop = desktop.start(f.opts(), function(s, e) got[#got + 1] = { s, e } end)
    f.find('ReadOne').on_exit({ code = 0, signal = 0, stdout = out })
    flush()
    eq(got, { { want ~= 'none' and want or nil } })
    stop()
  end
end)

test('falls back to Read when ReadOne fails', function()
  local f, got = fake(), {}
  local stop = desktop.start(f.opts(), function(s) got[#got + 1] = s end)
  f.find('ReadOne').on_exit({ code = 1, signal = 0, stdout = '' })
  flush()
  assert(f.find('Read'), 'Read not called')
  f.find('Read').on_exit({ code = 0, signal = 0, stdout = '(<<uint32 1>>,)' })
  flush()
  eq(got, { 'dark' })
  stop()
end)

test('read failure reports error', function()
  local f, got = fake(), {}
  local stop = desktop.start(f.opts(), function(s, e) got[#got + 1] = { s, e } end)
  f.find('ReadOne').on_exit({ code = 1, signal = 0, stdout = '' })
  flush()
  f.find('Read').on_exit({ code = 1, signal = 0, stdout = '' })
  flush()
  eq(got, { { nil, 'could not read color-scheme' } })
  stop()
end)

test('monitor handles split chunks and unrelated lines', function()
  local f, got = fake(), {}
  local stop = desktop.start(f.opts(), function(s) got[#got + 1] = s == nil and 'nil' or s end)
  local out = f.find('monitor').opts.stdout
  local line = SIGNAL:format(2)
  out(nil, 'noise other signal <uint32 1>\n' .. line:sub(1, 30))
  out(nil, line:sub(31, 90))
  flush()
  eq(got, {})
  out(nil, line:sub(91) .. SIGNAL:format(1) .. SIGNAL:format(0))
  flush()
  eq(got, { 'light', 'dark', 'nil' })
  stop()
end)

test('signal supersedes late initial read', function()
  local f, got = fake(), {}
  local stop = desktop.start(f.opts(), function(s) got[#got + 1] = s end)
  f.find('monitor').opts.stdout(nil, SIGNAL:format(2))
  flush()
  f.find('ReadOne').on_exit({ code = 0, signal = 0, stdout = '(<<uint32 1>>,)' })
  flush()
  eq(got, { 'light' })
  stop()
end)

test('stop kills processes and silences callbacks', function()
  local f, got = fake(), {}
  local stop = desktop.start(f.opts(), function(s) got[#got + 1] = s end)
  f.find('monitor').opts.stdout(nil, SIGNAL:format(1)) -- scheduled, not yet delivered
  stop()
  for _, p in ipairs(f.calls) do assert(p.killed) end
  f.find('ReadOne').on_exit({ code = 0, signal = 0, stdout = '(<<uint32 1>>,)' })
  f.find('monitor').opts.stdout(nil, SIGNAL:format(2))
  flush()
  eq(got, {})
  stop() -- idempotent
end)

test('VimLeavePre cleans up', function()
  local f = fake()
  desktop.start(f.opts(), function() end)
  vim.api.nvim_exec_autocmds('VimLeavePre', {})
  for _, p in ipairs(f.calls) do assert(p.killed) end
end)

test('no gdbus or non-Linux yields nil without spawning', function()
  local f, got = fake(), {}
  local o = f.opts()
  o.executable = function() return false end
  desktop.start(o, function(s, e) got[#got + 1] = { s, e } end)
  o = f.opts()
  o.sysname = 'Darwin'
  desktop.start(o, function(s, e) got[#got + 1] = { s, e } end)
  flush()
  eq(got, { { nil, 'gdbus not available' }, { nil } })
  eq(#f.calls, 0)
end)

test('spawn failure is tolerated', function()
  local got = {}
  local stop = desktop.start({
    sysname = 'Linux',
    executable = function() return true end,
    system = function() error('boom') end,
  }, function(s, e) got[#got + 1] = { s, e } end)
  flush()
  assert(#got >= 1 and got[1][1] == nil)
  stop()
end)

test('custom provider is async, sanitized, and stoppable', function()
  local cb, stopped = nil, false
  local got = {}
  local stop = desktop.start({
    start = function(c)
      cb = c
      c('dark')
      return function() stopped = true end
    end,
  }, function(s, e) got[#got + 1] = { s, e } end)
  eq(got, {})
  flush()
  cb('bogus')
  flush()
  eq(got, { { 'dark' }, { nil } })
  stop()
  assert(stopped)
  cb('light')
  flush()
  eq(#got, 2)
end)

test('opts.provider custom provider and VimLeavePre cleanup', function()
  local stopped, got = false, {}
  local cb
  desktop.start({ provider = { start = function(c) cb = c; return function() stopped = true end end } },
    function(s) got[#got + 1] = s end)
  cb('light')
  flush()
  eq(got, { 'light' })
  vim.api.nvim_exec_autocmds('VimLeavePre', {})
  assert(stopped)
  cb('dark')
  flush()
  eq(got, { 'light' })
end)

test('read spawn failure reports error', function()
  local f, got = fake(), {}
  local o = f.opts()
  o.system = function(cmd, so, ex)
    if cmd[2] == 'call' then error('nospawn') end
    return f.system(cmd, so, ex)
  end
  local stop = desktop.start(o, function(s, e) got[#got + 1] = { s, e } end)
  flush()
  eq(#got, 1)
  assert(got[1][1] == nil and got[1][2]:find('nospawn'))
  stop()
end)

test('monitor ignores other signal methods and bounds buffer', function()
  local f, got = fake(), {}
  local stop = desktop.start(f.opts(), function(s) got[#got + 1] = s end)
  local out = f.find('monitor').opts.stdout
  out(nil, (SIGNAL:format(1):gsub('SettingChanged', 'Other')))
  out(nil, string.rep('x', 200 * 1024))
  out(nil, SIGNAL:format(2))
  flush()
  eq(got, { 'light' })
  stop()
end)

print(('desktop tests passed: %d'):format(passed))
