-- Benchmark init file, used as `nvim --headless -u tests/benchmark.lua`.
-- Driven by tests/benchmark.py through environment variables:
--   ATELIER_BENCH_ROOT      repo (or frozen archive) to load atelier from
--   ATELIER_BENCH_FIXTURE   fixture dir: themes/<name>/colors/<name>.lua + data/state.json
--   ATELIER_BENCH_SCENARIO  'atelier' | 'control'
--   ATELIER_BENCH_OUT       path of the JSON result file
--
-- 'control' puts the same theme dirs on the rtp and runs `:colorscheme` for
-- the persisted theme at VimEnter, with no atelier code at all. The delta
-- against 'atelier' is framework overhead; the control's own colorscheme
-- time is the (trivial) theme execution cost.
--
local uv = vim.uv or vim.loop
local function now() return uv.hrtime() / 1e6 end

local root = assert(os.getenv('ATELIER_BENCH_ROOT'), 'ATELIER_BENCH_ROOT')
local fixture = assert(os.getenv('ATELIER_BENCH_FIXTURE'), 'ATELIER_BENCH_FIXTURE')
local scenario = assert(os.getenv('ATELIER_BENCH_SCENARIO'), 'ATELIER_BENCH_SCENARIO')
local out = assert(os.getenv('ATELIER_BENCH_OUT'), 'ATELIER_BENCH_OUT')

local themes_dir = fixture .. '/themes'
local data_dir = fixture .. '/data'

local names = {}
for name, kind in vim.fs.dir(themes_dir) do
  if kind == 'directory' then names[#names + 1] = name end
end
table.sort(names)
local paths = {}
for i, n in ipairs(names) do paths[i] = themes_dir .. '/' .. n end

local persisted = vim.json.decode(table.concat(vim.fn.readfile(data_dir .. '/state.json'), '\n'))

local R = {
  scenario = scenario,
  theme_count = #names,
  expected_theme = persisted.theme,
  nvim = vim.version() and tostring(vim.version()) or nil,
}

local function managed_rtp_count()
  local n = 0
  for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
    if p:sub(1, #themes_dir + 1) == themes_dir .. '/' then n = n + 1 end
  end
  return n
end

local function atelier_modules()
  local mods = {}
  for k in pairs(package.loaded) do
    if k == 'atelier' or k:sub(1, 8) == 'atelier.' then mods[#mods + 1] = k end
  end
  table.sort(mods)
  return mods
end

local function snapshot()
  local mods = atelier_modules()
  return {
    colors_name = vim.g.colors_name,
    background = vim.o.background,
    managed_rtp = managed_rtp_count(),
    atelier_modules = #mods,
    atelier_module_names = mods,
  }
end

local t_pre
vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    t_pre = now()
    R.at_vimenter_start = snapshot()
  end,
})

local setup_ok, setup_err = pcall(function()
  if scenario == 'atelier' then
    vim.opt.rtp:prepend(root)
    local t0 = now()
    local atelier = require('atelier')
    local t1 = now()
    atelier.setup({ themes = paths, data_dir = data_dir, persist = true })
    local t2 = now()
    R.require_ms = t1 - t0
    R.setup_ms = t2 - t1
    R.require_plus_setup_ms = t2 - t0
    R.after_setup = snapshot()
  elseif scenario == 'control' then
    local t0 = now()
    for _, p in ipairs(paths) do vim.opt.rtp:prepend(p) end
    R.setup_ms = now() - t0
    R.require_ms = 0
    R.require_plus_setup_ms = R.setup_ms
    R.after_setup = snapshot()
    vim.api.nvim_create_autocmd('VimEnter', {
      once = true,
      callback = function() vim.cmd.colorscheme(persisted.theme) end,
    })
  else
    error('unknown scenario ' .. scenario)
  end
end)
if not setup_ok then
  io.stderr:write('benchmark: ' .. tostring(setup_err) .. '\n')
  vim.cmd('cquit 2')
end

-- Registered after setup(), so it runs after atelier's own VimEnter handler.
vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  callback = function()
    local t_post = now()
    R.errmsg = vim.v.errmsg ~= '' and vim.v.errmsg or nil
    R.vimenter_resolution_ms = t_post - t_pre
    R.at_vimenter_end = snapshot()
    if scenario == 'atelier' then
      local ok, cur = pcall(function() return require('atelier').current() end)
      R.atelier_current = ok and cur or nil
    end
    R.loaded_by_setup = R.after_setup.colors_name == persisted.theme
    R.loaded_at_vimenter = R.at_vimenter_end.colors_name == persisted.theme
    R.colors_name_ok = R.at_vimenter_end.colors_name == persisted.theme
    vim.fn.writefile({ vim.json.encode(R) }, out)
    vim.schedule(function() vim.cmd('qa!') end)
  end,
})
