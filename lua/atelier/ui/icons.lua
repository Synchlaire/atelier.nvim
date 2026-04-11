-- Status glyphs. Falls back to ASCII when Nerd Fonts aren't around.
-- We don't try to autodetect — users can override via the table.
--
local M = {}

M.nerd = {
  installed = '',
  missing   = '',
  installing = '',
  updating  = '',
  failed    = '',
  current   = '•',
  expanded  = '▾',
  collapsed = '▸',
  divider   = '─',
  sep       = '·',
}

M.ascii = {
  installed = '[+]',
  missing   = '[ ]',
  installing = '...',
  updating  = '...',
  failed    = '[!]',
  current   = '*',
  expanded  = '-',
  collapsed = '+',
  divider   = '-',
  sep       = '.',
}

---@param use_ascii boolean
function M.set(use_ascii)
  M.active = use_ascii and M.ascii or M.nerd
end

M.active = M.nerd

return M
