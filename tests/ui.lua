-- UI control strip tests. Run from the repo root:
--   nvim --headless -u NONE -l tests/ui.lua
-- Real Volt drawing is exercised when a checkout is found via
-- $ATELIER_VOLT_PATH (directory containing lua/volt) or any `volt` on the
-- runtimepath; otherwise those tests are skipped with a notice.
local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local passed, skipped = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(('%s: %s'):format(name, err)) end
  passed = passed + 1
end

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected),
    ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function has_volt()
  return #vim.api.nvim_get_runtime_file('lua/volt/init.lua', false) > 0
end

local volt_path = vim.env.ATELIER_VOLT_PATH
if volt_path and volt_path ~= '' then vim.opt.runtimepath:append(volt_path) end
-- Phase 1 must run without Volt: hide it until the Volt tests start.
local volt_rtp = vim.deepcopy(vim.o.runtimepath)
local function hide_volt()
  local keep = {}
  for _, p in ipairs(vim.opt.runtimepath:get()) do
    if not vim.uv.fs_stat(vim.fs.joinpath(p, 'lua', 'volt', 'init.lua')) then keep[#keep + 1] = p end
  end
  vim.opt.runtimepath = keep
  package.loaded['volt'] = nil
end
local function show_volt() vim.o.runtimepath = volt_rtp end

local data_dir = vim.fn.tempname() -- isolated; never the user's stdpath

local function new_state(extra)
  local State = require('atelier.state')
  -- Built-in specs (no URLs, nothing to install) and a validated config so
  -- the fixture matches production on every supported Neovim version.
  local config = require('atelier.config').normalize({
    themes = {
      { 'alpha', auto = true, background = 'dark' },
      { 'beta' },
    },
    mode = 'auto',
    persist = false,
    data_dir = data_dir,
    -- no-op provider: never query the live desktop
    desktop_provider = { start = function() return function() end end },
  })
  local state = State.new(config)
  for _, rt in ipairs(state.themes) do
    rt.status = 'installed'
    rt.themes = { rt.spec.name .. '-one' }
  end
  state.by_name.alpha.expanded = true
  state.current = { spec_name = 'alpha', theme = 'alpha-one', background = 'dark', mode = 'auto' }
  for k, v in pairs(extra or {}) do state[k] = v end
  return state
end

local function open(state)
  package.loaded['atelier.ui.window'] = nil
  local Window = require('atelier.ui.window')
  local w = Window.open(state)
  w:render()
  return w, Window
end

local function strip_marks(w)
  local out = {}
  local ns = require('atelier.ui.volt').NS
  local marks = vim.api.nvim_buf_get_extmarks(w.buf, ns, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    out[m[2] + 1] = m[4].virt_text
  end
  return out
end

local function marks_text(virt)
  local t = {}
  for _, seg in ipairs(virt or {}) do t[#t + 1] = seg[1] end
  return table.concat(t)
end

local function atelier_floats()
  local n = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'atelier' then n = n + 1 end
  end
  return n
end

local function resize_listeners()
  local n = 0
  for _, ac in ipairs(vim.api.nvim_get_autocmds({ event = 'VimResized' })) do
    if ac.group_name and ac.group_name:match('^atelier%.window%.') then n = n + 1 end
  end
  return n
end

local mouse_before = vim.o.mouse

hide_volt()

test('without volt the strip is plain text with a visible hint', function()
  local state = new_state()
  local w = open(state)
  assert(not w.volt)
  local text = table.concat(vim.api.nvim_buf_get_lines(w.buf, 0, -1, false), '\n')
  assert(text:find('Light', 1, true) and text:find('Auto', 1, true), text)
  assert(text:find('nvzone/volt', 1, true), 'missing actionable hint')
  assert(w.rows[2].kind == 'control')
  assert(package.loaded['volt'] == nil)
  w:close()
  eq(atelier_floats(), 0)
end)

test('highlights rebuild after ColorScheme and keep user overrides', function()
  local H = require('atelier.ui.highlights')
  vim.api.nvim_set_hl(0, 'AtelierControl', { fg = '#ff0000' })
  H.setup()
  H.setup() -- idempotent: still one listener
  local n = #vim.api.nvim_get_autocmds({ event = 'ColorScheme', group = 'AtelierHighlights' })
  eq(n, 1)
  eq(vim.api.nvim_get_hl(0, { name = 'AtelierControl' }).fg, 0xff0000)
  vim.cmd.colorscheme('default')
  local hl = vim.api.nvim_get_hl(0, { name = 'AtelierControlActive' })
  assert(hl.reverse, 'AtelierControlActive not rebuilt')
  assert(next(vim.api.nvim_get_hl(0, { name = 'AtelierSpecHeader', link = true })) ~= nil)
  vim.api.nvim_set_hl(0, 'AtelierControl', {})
  H.define()
end)

show_volt()

if not has_volt() then
  skipped = 1
  print('atelier ui: volt not found (set ATELIER_VOLT_PATH); skipping Volt drawing tests')
else
  test('volt draws the strip over reserved lines without global side effects', function()
    local state = new_state()
    local w = open(state)
    assert(w.volt)
    local marks = strip_marks(w)
    local l2, l3, l4 = marks_text(marks[2]), marks_text(marks[3]), marks_text(marks[4])
    for _, label in ipairs({ 'Light', 'Dark', 'Auto' }) do assert(l2:find(label, 1, true), l2) end
    assert(l3:find('applied auto', 1, true) and l3:find('bg ' .. vim.o.background, 1, true), l3)
    assert(l4:find('Install', 1, true) and l4:find('Update', 1, true), l4)
    eq(w.rows[2].kind, 'control')
    eq(w.rows[5].kind, 'rule')
    eq(vim.api.nvim_buf_get_lines(w.buf, 1, 4, false), { '', '', '' })
    -- no Volt event layer, no mouse option changes
    eq(vim.o.mouse, mouse_before)
    assert(package.loaded['volt.events'] == nil, 'volt.events loaded')
    assert(vim.g.extmarks_events == nil and vim.g.nvmark_hovered == nil)
    w:close()
    assert(require('volt.state')[w.buf] == nil)
  end)

  test('applied vs preview draft and effective background are distinct', function()
    local state = new_state()
    local w = open(state)
    state.current.mode = 'dark'
    state.bus:emit('state_changed')
    local seg = {}
    for _, s in ipairs(strip_marks(w)[2]) do seg[#seg + 1] = s end
    local function group_of(label)
      for _, s in ipairs(seg) do if s[1]:find(label, 1, true) then return s[2] end end
    end
    eq(group_of('Dark'), 'AtelierControlActive')
    eq(group_of('Light'), 'AtelierControl')
    state.ui.previewed = { spec_name = 'alpha', theme = 'alpha-one', mode = 'light' }
    state.bus:emit('state_changed')
    seg = strip_marks(w)[2]
    eq(group_of('Light'), 'AtelierControlDraft')
    local status = marks_text(strip_marks(w)[3])
    assert(status:find('applied dark', 1, true) and status:find('preview light', 1, true), status)
    w:close()
  end)

  test('clicking a mode button calls on_mode; list rows still take the cursor', function()
    local state = new_state()
    local w = open(state)
    local got
    w.on_mode = function(mode) got = mode; return true end
    local click = vim.fn.maparg('<LeftMouse>', 'n', false, true)
    assert(type(click.callback) == 'function', 'no buffer-local mouse map')
    local items = require('volt.state')[w.buf].clickables[2]
    local target
    for _, it in ipairs(items) do
      if it.actions and it.col_end - it.col_start >= 4 then target = target or {} ; target[#target + 1] = it end
    end
    eq(#target, 3)
    local real = rawget(vim.fn, 'getmousepos')
    local function click_at(line, col)
      rawset(vim.fn, 'getmousepos', function()
        return { winid = w.win, line = line, wincol = col + 1, column = col + 1 }
      end)
      vim.api.nvim_win_call(w.win, click.callback)
    end
    click_at(2, target[2].col_start + 1) -- Dark
    eq(got, 'dark')
    click_at(2, target[1].col_start)     -- Light
    eq(got, 'light')
    -- a theme row moves the cursor
    local theme_line
    for i, r in ipairs(w.rows) do if r.kind == 'theme' then theme_line = i break end end
    click_at(theme_line, 6)
    eq(vim.api.nvim_win_get_cursor(w.win)[1], theme_line)
    -- on_mode returning false surfaces feedback
    w.on_mode = function() return false end
    click_at(2, target[3].col_start + 1)
    assert(state.ui.message and state.ui.message:find('auto', 1, true), state.ui.message)
    rawset(vim.fn, 'getmousepos', real) -- nil restores the lazy lookup
    w:close()
  end)

  test('operation buttons reuse buffer-local key actions', function()
    local state = new_state()
    local w = open(state)
    local called = 0
    vim.keymap.set('n', 'I', function() called = called + 1 end, { buffer = w.buf })
    assert(w:invoke_key('I'))
    eq(called, 1)
    assert(not w:invoke_key('<F13>'))
    assert(state.ui.message:find('No action', 1, true))
    w:close()
  end)

  test('operation progress replaces the action row', function()
    local state = new_state()
    local w = open(state)
    state.operation = { kind = 'install', completed = 2, total = 4, failed = 1 }
    state.bus:emit('state_changed')
    local l4 = marks_text(strip_marks(w)[4])
    assert(l4:find('INSTALL 2/4', 1, true) and l4:find('1 failed', 1, true), l4)
    w:close()
  end)

  test('help card clears the strip, closing it restores it', function()
    local state = new_state()
    local w = open(state)
    state.ui.help = true
    state.bus:emit('state_changed')
    eq(vim.tbl_count(strip_marks(w)), 0)
    state.ui.help = false
    state.bus:emit('state_changed')
    eq(vim.tbl_count(strip_marks(w)), 3)
    w:close()
  end)

  test('narrow terminals keep every fact inside the window width', function()
    local state = new_state()
    local saved = vim.o.columns
    local w = open(state)
    for _, cols in ipairs({ 80, 40, 30, 24 }) do
      vim.o.columns = cols
      w:resize()
      eq(vim.api.nvim_win_get_width(w.win), w.width)
      assert(w.width <= math.floor(cols * 0.8))
      for _, v in pairs(strip_marks(w)) do
        assert(vim.fn.strdisplaywidth(marks_text(v)) <= w.width, marks_text(v))
      end
      local l2 = marks_text(strip_marks(w)[2])
      assert(l2:find('L', 1, true) and l2:find('D', 1, true) and l2:find('A', 1, true), l2)
      assert(marks_text(strip_marks(w)[3]):find('auto', 1, true))
    end
    vim.o.columns = saved
    w:close()
  end)

  test('reopen replaces the window; close leaves no listeners', function()
    local state = new_state()
    package.loaded['atelier.ui.window'] = nil
    local Window = require('atelier.ui.window')
    local first = Window.open(state)
    local closed = 0
    first.on_close = function() closed = closed + 1 end
    local second = Window.open(state)
    eq(closed, 1)
    eq(atelier_floats(), 1)
    eq(resize_listeners(), 1)
    second:render()
    second:close()
    eq(atelier_floats(), 0)
    eq(resize_listeners(), 0)
    eq(Window.get(), nil)
    eq(vim.o.mouse, mouse_before)
  end)

  test('setup failures close the window and release the preview', function()
    local state = new_state()
    local Volt = require('atelier.ui.volt')

    -- 1. control attach fails inside the window module
    local real_attach = Volt.attach
    Volt.attach = function() error('attach boom') end
    package.loaded['atelier.ui.window'] = nil
    local ok, err = pcall(require('atelier.ui.window').open, state)
    Volt.attach = real_attach
    assert(not ok and err:find('could not set up the workshop window', 1, true)
      and err:find('attach boom', 1, true), tostring(err))
    eq(atelier_floats(), 0)
    eq(resize_listeners(), 0)

    -- 2. a later setup step fails after the preview exists
    local function open_with(patch)
      for _, m in ipairs({ 'atelier.ui', 'atelier.ui.window', 'atelier.ui.keymap', 'atelier.ui.preview' }) do
        package.loaded[m] = nil
      end
      local K = require('atelier.ui.keymap')
      local real = K.attach
      K.attach = patch
      package.loaded['atelier.ui.keymap'] = K
      local ok2, err2 = pcall(function() return require('atelier.ui').open(state) end)
      K.attach = real
      return ok2, err2
    end
    local ok2, err2 = open_with(function() error('keymap boom') end)
    assert(not ok2 and err2:find('could not open the picker', 1, true)
      and err2:find('keymap boom', 1, true), tostring(err2))
    eq(atelier_floats(), 0)
    eq(resize_listeners(), 0)
    eq(state.preview, nil)
    eq(state.ui.previewed, nil)

    -- 3. a clean open still works afterwards
    local ok3 = open_with(require('atelier.ui.keymap').attach)
    assert(ok3)
    eq(atelier_floats(), 1)
    require('atelier.ui.window').get():close()
    eq(state.preview, nil)
    for _, m in ipairs({ 'atelier.ui', 'atelier.ui.window', 'atelier.ui.keymap', 'atelier.ui.preview' }) do
      package.loaded[m] = nil
    end
  end)

  test('redraw after external buffer wipe does not error', function()
    local state = new_state()
    local w = open(state)
    vim.api.nvim_buf_delete(w.buf, { force = true })
    state.bus:emit('state_changed')
    eq(atelier_floats(), 0)
    eq(resize_listeners(), 0)
  end)
end

vim.fn.delete(data_dir, 'rf')
print(('atelier ui: %d tests passed%s'):format(passed, skipped > 0 and ' (volt tests skipped)' or ''))
