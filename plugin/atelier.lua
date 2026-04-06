-- :Atelier opens the picker. The plugin module is intentionally tiny; all
-- behavior lives under lua/atelier/. We register the user command lazily —
-- it only require()s atelier the first time it's actually invoked.
--
if vim.g.loaded_atelier == 1 then return end
vim.g.loaded_atelier = 1

vim.api.nvim_create_user_command('Atelier', function(opts)
  local sub = opts.fargs[1]
  local atelier = require('atelier')
  if sub == 'install' then
    atelier.install()
  elseif sub == 'update' then
    atelier.update()
  elseif sub == 'clean' then
    atelier.clean()
  else
    atelier.pick()
  end
end, {
  nargs = '?',
  complete = function() return { 'install', 'update', 'clean' } end,
  desc = 'Open the atelier theme picker (or run install/update/clean)',
})
