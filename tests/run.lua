local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local passed = 0
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function test(name, fn)
  local temp = vim.fn.tempname()
  vim.fn.mkdir(temp, 'p')
  local rtp, bg, theme = vim.o.runtimepath, vim.o.background, vim.g.colors_name
  local notify = vim.notify
  local ok, err = pcall(fn, temp)
  vim.notify = notify
  local state = require('atelier.api')._state()
  if state then require('atelier.appearance').stop(state) end
  vim.o.runtimepath = rtp
  vim.o.background = bg
  pcall(vim.cmd.colorscheme, theme or 'default')
  vim.fn.delete(temp, 'rf')
  if not ok then error(('%s: %s'):format(name, err)) end
  passed = passed + 1
end

local function plugin(dir, names)
  vim.fn.mkdir(vim.fs.joinpath(dir, 'colors'), 'p')
  for _, name in ipairs(names) do
    vim.fn.writefile({
      'vim.cmd("highlight clear")',
      'vim.g.colors_name = ' .. string.format('%q', name),
      'vim.g.atelier_theme_executions = (vim.g.atelier_theme_executions or 0) + 1',
    }, vim.fs.joinpath(dir, 'colors', name .. '.lua'))
  end
  return dir
end

local function config_for(temp, extra)
  local dir = plugin(vim.fs.joinpath(temp, 'provider'), { 'fixture_dark', 'fixture_light' })
  return vim.tbl_extend('force', {
    data_dir = vim.fs.joinpath(temp, 'data'),
    desktop_provider = { start = function() return function() end end },
    themes = {{ dir, name = 'pair', backgrounds = { fixture_dark = 'dark', fixture_light = 'light' } }},
  }, extra or {})
end

local function saved(config)
  return table.concat(vim.fn.readfile(vim.fs.joinpath(config.data_dir, 'state.json')), '\n')
end

test('config normalizes background metadata and explicit capabilities', function()
  local config = require('atelier.config').normalize({
    persist = false,
    themes = {{ 'owner/theme.nvim', auto = true, background = 'dark', backgrounds = { day = 'light' } }},
  })
  eq(config.themes[1].name, 'theme')
  eq(config.themes[1].background, 'dark')
  eq(config.themes[1].backgrounds.day, 'light')
  eq(config.themes[1].auto, true)
  eq(config.mode, 'auto')
  assert(not pcall(require('atelier.config').normalize, { mode = 'day' }))
  assert(not pcall(require('atelier.config').normalize, { desktop_provider = {} }))
end)

test('persistence round-trips preference separately from effective background', function(temp)
  local persist = require('atelier.persist')
  local current = { spec_name = 'plain', theme = 'plain', background = 'light', mode = 'auto' }
  assert(persist.write(temp, current))
  eq(persist.read(temp), current)
end)

test('legacy persistence migrates explicit background and ignores corrupt data', function(temp)
  local persist = require('atelier.persist')
  local path = vim.fs.joinpath(temp, 'state.json')
  vim.fn.writefile({ '{"spec_name":"plain","theme":"plain","background":"light"}' }, path)
  eq(persist.read(temp).mode, nil) -- setup resolves legacy metadata with the spec available.
  vim.fn.writefile({ '{"spec_name":3,"background":"pink","mode":"day"}' }, path)
  eq(persist.read(temp), {})
  vim.fn.writefile({ '{broken' }, path)
  eq(persist.read(temp), {})
  vim.fn.writefile({ string.rep('x', 65537) }, path)
  eq(persist.read(temp), {})
end)

test('persistence reports write failure without replacing previous state', function(temp)
  local persist = require('atelier.persist')
  assert(persist.write(temp, { spec_name = 'plain', theme = 'plain', mode = 'dark' }))
  local before = vim.fn.readfile(vim.fs.joinpath(temp, 'state.json'))
  local ok = persist.write(vim.fs.joinpath(temp, 'state.json', 'impossible'), {})
  eq(ok, false)
  eq(vim.fn.readfile(vim.fs.joinpath(temp, 'state.json')), before)
end)

test('status and discovery never activate installed providers', function(temp)
  local config = require('atelier.config').normalize(config_for(temp))
  local state = require('atelier.state').new(config)
  local manager = require('atelier.manager')
  local before = vim.o.runtimepath
  manager.refresh_status(state)
  eq(state.themes[1].status, 'installed')
  eq(manager.discover(state, state.themes[1]), { 'fixture_dark', 'fixture_light' })
  eq(vim.o.runtimepath, before)
end)

test('missing local provider does not scan unrelated runtime themes', function(temp)
  local config = require('atelier.config').normalize({ themes = { vim.fs.joinpath(temp, 'missing') } })
  local state = require('atelier.state').new(config)
  eq(require('atelier.manager').discover(state, state.themes[1]), {})
end)

test('setup restores only the active provider synchronously', function(temp)
  local cfg = config_for(temp)
  local second = plugin(vim.fs.joinpath(temp, 'unused'), { 'fixture_unused' })
  cfg.themes[#cfg.themes + 1] = { second, name = 'unused' }
  require('atelier.persist').write(cfg.data_dir, {
    spec_name = 'pair', theme = 'fixture_light', background = 'light', mode = 'light',
  })
  local before = saved(cfg)
  require('atelier').setup(cfg)
  eq(vim.g.colors_name, 'fixture_light')
  eq(vim.o.background, 'light')
  local paths = vim.opt.rtp:get()
  assert(vim.tbl_contains(paths, cfg.themes[1][1]))
  assert(not vim.tbl_contains(paths, second))
  eq(require('atelier.api')._state().themes[2].status, 'unknown')
  eq(saved(cfg), before)
  assert(not package.loaded['atelier.ui'])
  assert(not package.loaded.volt)
end)

test('setup without persisted selection activates nothing', function(temp)
  local cfg = config_for(temp)
  local before = vim.o.runtimepath
  require('atelier').setup(cfg)
  eq(vim.o.runtimepath, before)
  eq(require('atelier').current().spec_name, nil)
end)

test('API load activates once and persists the effective selection', function(temp)
  local cfg = config_for(temp, { mode = 'dark' })
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  assert(require('atelier').load('pair', 'fixture_dark'))
  local count = 0
  for _, path in ipairs(vim.opt.rtp:get()) do if path == cfg.themes[1][1] then count = count + 1 end end
  eq(count, 1)
  eq(require('atelier.persist').read(cfg.data_dir), require('atelier').current())
  eq(require('atelier').load('missing'), false)
end)

test('preview mode is reversible and never writes persisted selection', function(temp)
  local cfg = config_for(temp, { mode = 'dark' })
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  local before = saved(cfg)
  local state = require('atelier.api')._state()
  local preview = require('atelier.ui.preview').new(state)
  assert(preview:set_mode('light'))
  eq(vim.g.colors_name, 'fixture_light')
  eq(vim.o.background, 'light')
  eq(state.current.mode, 'dark')
  eq(saved(cfg), before)
  preview:cleanup()
  eq(vim.g.colors_name, 'fixture_dark')
  eq(vim.o.background, 'dark')
  eq(saved(cfg), before)
end)

test('preview commit shares API persistence and runs on_load only on commit', function(temp)
  local calls = 0
  local cfg = config_for(temp, { mode = 'dark', on_load = function() calls = calls + 1 end })
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  local state = require('atelier.api')._state()
  local preview = require('atelier.ui.preview').new(state)
  assert(preview:set_mode('light'))
  eq(calls, 1)
  assert(preview:commit_item({ spec_name = 'pair', theme = 'fixture_dark' }))
  preview:cleanup()
  eq(calls, 2)
  eq(state.current, { spec_name = 'pair', choice = 'fixture_dark', theme = 'fixture_light', background = 'light', mode = 'light' })
  eq(state.last_good, state.current)
  assert(state.last_good ~= state.current)
  eq(require('atelier.persist').read(cfg.data_dir), state.current)
end)

test('Snacks cancellation restores mode draft as well as theme and background', function(temp)
  require('atelier').setup(config_for(temp, { mode = 'dark' }))
  assert(require('atelier').load('pair', 'fixture_dark'))
  local state = require('atelier.api')._state()
  local preview = require('atelier.ui.preview').new(state)
  local handoff = preview:visual_snapshot()
  assert(preview:set_mode('light'))
  preview:restore_visual(handoff)
  eq(preview.mode, 'dark')
  eq(vim.g.colors_name, 'fixture_dark')
  eq(state.ui.previewed, nil)
  preview:cleanup()
end)

test('failed colorscheme load restores visual state and leaves persistence unchanged', function(temp)
  local cfg = config_for(temp, { mode = 'dark' })
  vim.fn.writefile({ 'vim.cmd("highlight clear")', 'vim.o.background = "light"', 'error("broken theme")' },
    vim.fs.joinpath(cfg.themes[1][1], 'colors', 'broken.lua'))
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  local before = saved(cfg)
  eq(require('atelier').load('pair', 'broken'), false)
  eq(vim.g.colors_name, 'fixture_dark')
  eq(vim.o.background, 'dark')
  eq(require('atelier').current().theme, 'fixture_dark')
  eq(saved(cfg), before)
end)

test('variant choice is deterministic and respects only and except', function()
  local selection = require('atelier.selection')
  local spec = { name = 'pair', only = {}, except = { 'a' }, backgrounds = { z = 'dark', a = 'dark', day = 'light' } }
  eq(selection.variant_for(spec, 'dark'), 'z')
  assert(selection.supports_auto(spec))
  spec.only = { 'z' }
  eq(selection.supports_auto(spec), false)
end)

test('Auto never substitutes a base theme with only one declared background variant', function(temp)
  local starts = 0
  local dir = plugin(vim.fs.joinpath(temp, 'partial'), { 'partial', 'partial_day' })
  require('atelier').setup({
    themes = {{ dir, name = 'partial', backgrounds = { partial_day = 'light' } }},
    data_dir = vim.fs.joinpath(temp, 'data'),
    desktop_provider = { start = function() starts = starts + 1; return function() end end },
  })
  vim.o.background = 'light'
  assert(require('atelier').load('partial', 'partial'))
  eq(vim.g.colors_name, 'partial')
  eq(require('atelier').current().theme, 'partial')
  eq(starts, 0)
end)

test('fixed themes do not start a desktop subscription', function(temp)
  local starts = 0
  local cfg = config_for(temp)
  cfg.themes[1].backgrounds = nil
  cfg.themes[1].background = 'dark'
  cfg.desktop_provider = { start = function() starts = starts + 1; return function() end end }
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  eq(starts, 0)
  eq(require('atelier').set_mode('light'), false)
  eq(vim.g.colors_name, 'fixture_dark')
end)

test('desktop changes follow Auto and pause until preview cancellation', function(temp)
  local change, stops = nil, 0
  local cfg = config_for(temp, { desktop_provider = { start = function(callback)
    change = callback
    return function() stops = stops + 1 end
  end } })
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  assert(vim.wait(1000, function() return change ~= nil end, 5))
  change('light')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_light' end, 5))
  eq(require('atelier').current().mode, 'auto')
  local cache = require('atelier.persist').read(cfg.data_dir)
  eq(cache.choice, 'fixture_dark')
  eq(cache.background, 'light')
  eq(cache.mode, 'auto')
  local state = require('atelier.api')._state()
  local preview = require('atelier.ui.preview').new(state)
  change('dark')
  vim.wait(20, function() return false end)
  eq(vim.g.colors_name, 'fixture_light')
  preview:cleanup()
  eq(vim.g.colors_name, 'fixture_dark')
  assert(require('atelier').set_mode('light'))
  assert(stops > 0)
  change('dark')
  vim.wait(20, function() return false end)
  eq(vim.g.colors_name, 'fixture_light')
end)

test('direct selections are not blocked or substituted by the previous mode', function(temp)
  local cfg = config_for(temp, { mode = 'dark' })
  local fixed = plugin(vim.fs.joinpath(temp, 'fixed'), { 'fixed_light' })
  cfg.themes[#cfg.themes + 1] = { fixed, name = 'fixed', background = 'light' }
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  assert(require('atelier').load('pair', 'fixture_light'))
  eq(vim.g.colors_name, 'fixture_light')
  eq(require('atelier').current().mode, 'light')
  assert(require('atelier').set_mode('dark'))
  assert(require('atelier').load('fixed', 'fixed_light'))
  eq(vim.g.colors_name, 'fixed_light')
  eq(require('atelier').current().mode, 'light')
end)

test('Auto round trip and restart preserve the chosen non-first variant', function(temp)
  local change
  local cfg = config_for(temp, { desktop_provider = { start = function(cb)
    change = cb
    return function() end
  end } })
  plugin(cfg.themes[1][1], { 'fixture_storm' })
  cfg.themes[1].backgrounds.fixture_storm = 'dark'
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_storm'))
  change('light')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_light' end, 5))
  eq(require('atelier').current().choice, 'fixture_storm')
  change('dark')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_storm' end, 5))
  change('light')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_light' end, 5))
  require('atelier').setup(cfg)
  eq(vim.g.colors_name, 'fixture_light') -- cached latest background, before the next async read.
  eq(require('atelier').current().choice, 'fixture_storm')
  change('dark')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_storm' end, 5))
end)

test('applying the unchanged effective Auto row preserves its original anchor', function(temp)
  local change
  local cfg = config_for(temp, { desktop_provider = { start = function(cb)
    change = cb
    return function() end
  end } })
  plugin(cfg.themes[1][1], { 'fixture_storm' })
  cfg.themes[1].backgrounds.fixture_storm = 'dark'
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_storm'))
  change('light')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_light' end, 5))
  local state = require('atelier.api')._state()
  local preview = require('atelier.ui.preview').new(state)
  assert(preview:commit_item({ spec_name = 'pair', theme = 'fixture_light' }))
  preview:cleanup()
  eq(state.current.choice, 'fixture_storm')
end)

test('legacy declared background restores Auto but an undeclared override stays explicit', function(temp)
  local cfg = config_for(temp)
  vim.fn.mkdir(cfg.data_dir, 'p')
  local path = vim.fs.joinpath(cfg.data_dir, 'state.json')
  vim.fn.writefile({ '{"spec_name":"pair","theme":"fixture_dark","background":"dark"}' }, path)
  require('atelier').setup(cfg)
  eq(require('atelier').current().mode, 'auto')
  cfg.themes[1].backgrounds = nil
  cfg.themes[1].auto = true
  vim.fn.writefile({ '{"spec_name":"pair","theme":"fixture_dark","background":"light"}' }, path)
  require('atelier').setup(cfg)
  eq(require('atelier').current().mode, 'light')
  eq(vim.o.background, 'light')
end)

test('legacy fixed theme restores even when the configured mode is opposite', function(temp)
  local cfg = config_for(temp, { mode = 'light' })
  cfg.themes[1].backgrounds = nil
  cfg.themes[1].background = 'dark'
  vim.fn.mkdir(cfg.data_dir, 'p')
  vim.fn.writefile({ '{"spec_name":"pair","theme":"fixture_dark","background":"dark"}' },
    vim.fs.joinpath(cfg.data_dir, 'state.json'))
  local before = saved(cfg)
  require('atelier').setup(cfg)
  eq(vim.g.colors_name, 'fixture_dark')
  eq(require('atelier').current().spec_name, 'pair')
  eq(require('atelier').current().mode, 'dark')
  eq(saved(cfg), before)
end)

test('Auto preview subscribes without changing the committed selection', function(temp)
  local change, stops = nil, 0
  local cfg = config_for(temp, { mode = 'dark', desktop_provider = { start = function(cb)
    change = cb
    return function() stops = stops + 1 end
  end } })
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  local before = saved(cfg)
  local state = require('atelier.api')._state()
  local preview = require('atelier.ui.preview').new(state)
  assert(preview:set_mode('auto'))
  change('light')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_light' end, 5))
  eq(state.current.mode, 'dark')
  eq(state.ui.previewed.mode, 'auto')
  eq(saved(cfg), before)
  preview:cleanup()
  eq(vim.g.colors_name, 'fixture_dark')
  eq(state.current.mode, 'dark')
  eq(saved(cfg), before)
  assert(stops > 0)
end)

test('adaptive themes receive background before execution', function(temp)
  local cfg = config_for(temp)
  cfg.themes[1].backgrounds = nil
  cfg.themes[1].auto = true
  vim.fn.writefile({ 'vim.g.colors_name="adaptive"', 'vim.g.fixture_seen_background=vim.o.background' },
    vim.fs.joinpath(cfg.themes[1][1], 'colors', 'adaptive.lua'))
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'adaptive'))
  assert(require('atelier').set_mode('light'))
  eq(vim.g.fixture_seen_background, 'light')
end)

test('API apply ends an open preview so cancellation cannot undo the new selection', function(temp)
  require('atelier').setup(config_for(temp, { mode = 'dark' }))
  assert(require('atelier').load('pair', 'fixture_dark'))
  local state = require('atelier.api')._state()
  local preview = require('atelier.ui.preview').new(state)
  assert(preview:set_mode('light'))
  assert(require('atelier').load('pair', 'fixture_light'))
  preview:cleanup() -- stale close callback must be harmless.
  eq(state.preview, nil)
  eq(state.current.theme, 'fixture_light')
  eq(vim.g.colors_name, 'fixture_light')
  eq(preview:commit_item({ spec_name = 'pair', theme = 'fixture_dark' }), false)
end)

test('automatic cache updates do not replace a different saved preference', function(temp)
  local change
  local cfg = config_for(temp, { desktop_provider = { start = function(cb)
    change = cb
    return function() end
  end } })
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  local persist = require('atelier.persist')
  local external = { spec_name = 'other-session', theme = 'other', choice = 'other', mode = 'dark', background = 'dark' }
  assert(persist.write(cfg.data_dir, external))
  change('light')
  assert(vim.wait(1000, function() return vim.g.colors_name == 'fixture_light' end, 5))
  eq(persist.read(cfg.data_dir), external)
end)

test('persist false neither reads nor writes a previous selection', function(temp)
  local cfg = config_for(temp, { mode = 'dark', persist = false })
  require('atelier.persist').write(cfg.data_dir, { spec_name = 'pair', theme = 'fixture_light', mode = 'light' })
  local before = saved(cfg)
  require('atelier').setup(cfg)
  eq(require('atelier').current().spec_name, nil)
  assert(require('atelier').load('pair', 'fixture_dark'))
  eq(saved(cfg), before)
end)

test('failed startup restoration keeps the previous theme and saved state', function(temp)
  local cfg = config_for(temp)
  vim.cmd.colorscheme('default')
  require('atelier.persist').write(cfg.data_dir, { spec_name = 'pair', theme = 'removed_variant', mode = 'auto' })
  local before = saved(cfg)
  local warning
  vim.notify = function(message) warning = message end
  require('atelier').setup(cfg)
  assert(vim.wait(1000, function() return warning ~= nil end, 5))
  assert(warning:find('Could not restore selection', 1, true))
  eq(vim.g.colors_name, 'default')
  eq(require('atelier').current().spec_name, nil)
  eq(saved(cfg), before)
end)

test('repeated setup stops previous appearance subscriptions', function(temp)
  local stops = 0
  local cfg = config_for(temp, { desktop_provider = { start = function()
    return function() stops = stops + 1 end
  end } })
  require('atelier').setup(cfg)
  assert(require('atelier').load('pair', 'fixture_dark'))
  require('atelier').setup(config_for(temp, { persist = false }))
  assert(stops > 0)
end)

test('clean archives unknown theme directories', function(temp)
  local sites = vim.fs.joinpath(temp, 'sites')
  vim.fn.mkdir(vim.fs.joinpath(sites, 'known'), 'p')
  vim.fn.mkdir(vim.fs.joinpath(sites, 'unused'), 'p')
  vim.fn.writefile({ 'keep me' }, vim.fs.joinpath(sites, 'unused', 'marker'))
  local events = {}
  local state = {
    config = { data_dir = temp }, themes = {{ spec = { name = 'known', url = 'https://example.invalid/known' } }},
    ui = {}, bus = { emit = function(_, event) events[#events + 1] = event end },
  }
  local manager = require('atelier.manager')
  local plan = manager.clean_plan(state)
  eq(#plan, 1)
  local result = manager.clean(state, plan)
  eq(result.moved, 1)
  eq(result.failed, 0)
  assert(vim.fn.isdirectory(vim.fs.joinpath(sites, 'unused')) == 0)
  assert(vim.fn.filereadable(vim.fs.joinpath(result.trash_dir, 'unused', 'marker')) == 1)
  eq(events[#events], 'state_changed')
end)

test('git continuations run outside fast events', function()
  local called = false
  require('atelier.git').run({ 'git', '--version' }, nil, function(result)
    assert(result.ok, result.stderr)
    assert(not vim.in_fast_event())
    assert(vim.api.nvim_get_option_value('runtimepath', {}) ~= '')
    called = true
  end)
  assert(vim.wait(5000, function() return called end, 10), 'git callback timed out')
end)

test('install and update a local repository without activation', function(temp)
  local source = vim.fs.joinpath(temp, 'source')
  plugin(source, { 'sample' })
  local function git(args)
    local output = vim.fn.system(vim.list_extend({ 'git', '-C', source }, args))
    assert(vim.v.shell_error == 0, output)
  end
  git({ 'init', '-q' })
  git({ 'add', '.' })
  git({ '-c', 'user.name=Atelier Test', '-c', 'user.email=atelier@example.invalid', 'commit', '-qm', 'initial theme' })
  local spec = { name = 'sample', url = source }
  local rt = { spec = spec, status = 'unknown' }
  local state = {
    config = { data_dir = vim.fs.joinpath(temp, 'data'), parallel = 1 }, themes = { rt }, ui = {},
    bus = { emit = function() end },
  }
  local manager = require('atelier.manager')
  local before = vim.o.runtimepath
  local installed = false
  manager.install_missing(state, function() installed = true end)
  assert(vim.wait(5000, function() return installed end, 10), 'install timed out')
  eq(rt.status, 'installed')
  local dest = manager.dir_for(state, spec)
  assert(vim.fn.filereadable(vim.fs.joinpath(dest, 'colors', 'sample.lua')) == 1)
  eq(vim.o.runtimepath, before)
  local updated = false
  manager.update_all(state, function() updated = true end)
  assert(vim.wait(5000, function() return updated end, 10), 'update timed out')
  eq(rt.status, 'installed')
  eq(state.operation, nil)
  eq(vim.o.runtimepath, before)
  assert(manager.activate(state, rt))
  assert(vim.tbl_contains(vim.opt.rtp:get(), dest))
end)

print(('atelier: %d tests passed'):format(passed))
