-- Highlight groups for the picker. Linked to common defaults so the picker
-- inherits the user's colorscheme automatically.
--
local M = {}

local groups = {
  AtelierTitle      = { link = 'Title' },
  AtelierItem       = { link = 'Normal' },
  AtelierItemActive = { link = 'CursorLine' },
  AtelierStatusOk   = { link = 'DiagnosticOk' },
  AtelierStatusWarn = { link = 'DiagnosticWarn' },
  AtelierStatusErr  = { link = 'DiagnosticError' },
  AtelierStatusBusy = { link = 'DiagnosticInfo' },
  AtelierMuted      = { link = 'Comment' },
  AtelierKey        = { link = 'Special' },
  AtelierCurrent    = { link = 'String' },
}

function M.setup()
  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', def, { default = true }))
  end
end

return M
