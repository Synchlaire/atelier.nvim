local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local passed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    error(('%s: %s'):format(name, err))
  end
  passed = passed + 1
end

local function eq(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual))
  )
end

test('config normalizes background metadata', function()
  local config = require('atelier.config').normalize({
    persist = false,
    themes = {
      {
        'owner/theme.nvim',
        background = 'dark',
        backgrounds = { day = 'light' },
      },
    },
  })
  eq(config.themes[1].name, 'theme')
  eq(config.themes[1].background, 'dark')
  eq(config.themes[1].backgrounds.day, 'light')
end)

test('persistence round-trips optional background', function()
  local dir = vim.fn.tempname()
  local persist = require('atelier.persist')
  local current = { spec_name = 'plain', theme = 'plain', background = 'light' }
  persist.write(dir, current)
  eq(persist.read(dir), current)
  vim.fn.delete(dir, 'rf')
end)

test('preview commit persists background and snapshots state', function()
  local original_loader = package.loaded['atelier.loader']
  local original_persist = package.loaded['atelier.persist']
  local persisted

  package.loaded['atelier.loader'] = {
    load = function()
      vim.o.background = 'light'
      return true
    end,
    declared_background = function()
      return 'light'
    end,
  }
  package.loaded['atelier.persist'] = {
    write = function(_, current)
      persisted = vim.deepcopy(current)
    end,
  }
  package.loaded['atelier.ui.preview'] = nil

  local emitted = 0
  local state = {
    config = { persist = true, data_dir = '/unused', on_load = nil },
    current = {},
    ui = {},
    bus = {
      emit = function()
        emitted = emitted + 1
      end,
    },
  }
  local item = {
    spec_name = 'plain',
    theme = 'plain',
    rt = { status = 'installed', spec = { name = 'plain', background = 'light' } },
  }

  local preview = require('atelier.ui.preview').new(state)
  local ok = preview:commit_item(item)
  assert(ok)
  eq(state.current, { spec_name = 'plain', theme = 'plain', background = 'light' })
  eq(state.last_good, state.current)
  assert(state.last_good ~= state.current)
  eq(persisted, state.current)
  eq(emitted, 1)

  package.loaded['atelier.loader'] = original_loader
  package.loaded['atelier.persist'] = original_persist
  package.loaded['atelier.ui.preview'] = nil
end)

test('clean archives unknown theme directories', function()
  local temp = vim.fn.tempname()
  local sites = vim.fs.joinpath(temp, 'sites')
  vim.fn.mkdir(vim.fs.joinpath(sites, 'known'), 'p')
  vim.fn.mkdir(vim.fs.joinpath(sites, 'unused'), 'p')
  vim.fn.writefile({ 'keep me' }, vim.fs.joinpath(sites, 'unused', 'marker'))

  local events = {}
  local state = {
    config = { data_dir = temp },
    themes = {
      { spec = { name = 'known', url = 'https://example.invalid/known' } },
    },
    ui = {},
    bus = { emit = function(_, event) events[#events + 1] = event end },
  }

  local manager = require('atelier.manager')
  local plan = manager.clean_plan(state)
  eq(#plan, 1)
  eq(plan[1].name, 'unused')

  local result = manager.clean(state, plan)
  eq(result.moved, 1)
  eq(result.failed, 0)
  assert(vim.fn.isdirectory(vim.fs.joinpath(sites, 'unused')) == 0)
  assert(vim.fn.filereadable(vim.fs.joinpath(result.trash_dir, 'unused', 'marker')) == 1)
  assert(vim.fn.isdirectory(vim.fs.joinpath(sites, 'known')) == 1)
  eq(events[#events], 'state_changed')
  vim.fn.delete(temp, 'rf')
end)

test('git continuations run outside fast events', function()
  local called = false
  require('atelier.git').run({ 'git', '--version' }, nil, function(result)
    assert(result.ok, result.stderr)
    assert(not vim.in_fast_event())
    -- This is the API that failed when the callback ran in a fast event.
    assert(vim.api.nvim_get_option_value('runtimepath', {}) ~= '')
    called = true
  end)
  assert(vim.wait(5000, function() return called end, 10), 'git callback timed out')
end)

test('install and update a local theme repository', function()
  local temp = vim.fn.tempname()
  local source = vim.fs.joinpath(temp, 'source')
  vim.fn.mkdir(vim.fs.joinpath(source, 'colors'), 'p')
  vim.fn.writefile({ 'hi clear' }, vim.fs.joinpath(source, 'colors', 'sample.vim'))

  local function git(args)
    local output = vim.fn.system(vim.list_extend({ 'git', '-C', source }, args))
    assert(vim.v.shell_error == 0, output)
  end

  git({ 'init', '-q' })
  git({ 'add', '.' })
  git({ '-c', 'user.name=Atelier Test', '-c', 'user.email=atelier@example.invalid',
    'commit', '-qm', 'initial theme' })

  local spec = { name = 'sample', url = source }
  local rt = { spec = spec, status = 'unknown' }
  local state = {
    config = { data_dir = vim.fs.joinpath(temp, 'data'), parallel = 1 },
    themes = { rt },
    ui = {},
    bus = { emit = function() end },
  }
  local manager = require('atelier.manager')
  local installed = false
  manager.install_missing(state, function() installed = true end)
  assert(vim.wait(5000, function() return installed end, 10), 'install timed out')
  eq(rt.status, 'installed')
  local dest = manager.dir_for(state, spec)
  assert(vim.fn.filereadable(vim.fs.joinpath(dest, 'colors', 'sample.vim')) == 1)
  local occurrences = 0
  for _, path in ipairs(vim.opt.rtp:get()) do
    if path == dest then occurrences = occurrences + 1 end
  end
  eq(occurrences, 1)

  local updated = false
  manager.update_all(state, function() updated = true end)
  assert(vim.wait(5000, function() return updated end, 10), 'update timed out')
  eq(rt.status, 'installed')
  eq(state.operation, nil)

  vim.opt.rtp:remove(dest)
  vim.fn.delete(temp, 'rf')
end)

print(('atelier: %d tests passed'):format(passed))
