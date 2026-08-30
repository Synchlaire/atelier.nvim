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

test('snacks commit persists background and snapshots state', function()
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
  package.loaded['atelier.ui.snacks'] = nil

  local emitted = 0
  local state = {
    config = { persist = true, data_dir = '/unused', on_load = nil },
    bus = {
      emit = function()
        emitted = emitted + 1
      end,
    },
  }
  local item = {
    spec_name = 'plain',
    theme = 'plain',
    rt = { spec = { name = 'plain', background = 'light' } },
  }

  local ok = require('atelier.ui.snacks').commit(state, item, 'dark')
  assert(ok)
  eq(state.current, { spec_name = 'plain', theme = 'plain', background = 'light' })
  eq(state.last_good, state.current)
  assert(state.last_good ~= state.current)
  eq(persisted, state.current)
  eq(emitted, 1)

  package.loaded['atelier.loader'] = original_loader
  package.loaded['atelier.persist'] = original_persist
  package.loaded['atelier.ui.snacks'] = nil
end)

print(('atelier: %d tests passed'):format(passed))
