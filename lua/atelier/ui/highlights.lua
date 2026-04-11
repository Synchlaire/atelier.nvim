-- Highlight groups for the picker.
--
-- Wing OS vocabulary: monochrome hierarchy carried by opacity and weight,
-- color reserved for semantic feedback (status, current). Two-tier fallback
-- chain: prefer semantic float groups (FloatTitle, FloatBorder, NormalFloat)
-- that modern colorschemes define; fall back to long-standing generic groups
-- for older schemes.
--
-- All groups use `default = true` so user overrides (`nvim_set_hl`) win.
--
local M = {}

---@param name string
---@return boolean
local function has(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = true })
  if not ok or not hl then return false end
  return next(hl) ~= nil
end

---Pick the first group in `candidates` that actually exists, else the last.
---@param candidates string[]
---@return string
local function prefer(candidates)
  for _, name in ipairs(candidates) do
    if has(name) then return name end
  end
  return candidates[#candidates]
end

function M.setup()
  local groups = {
    AtelierNormal       = { link = 'NormalFloat' },
    AtelierBorder       = { link = 'FloatBorder' },
    AtelierTitle        = { link = prefer({ 'FloatTitle', 'Title' }) },
    AtelierSubtle       = { link = prefer({ 'NonText', 'Comment' }) },
    AtelierDivider      = { link = prefer({ 'WinSeparator', 'LineNr' }) },
    AtelierSpecHeader   = { link = prefer({ 'Function', 'Identifier' }) },
    AtelierTheme        = { link = 'Normal' },
    AtelierThemeBg      = { link = 'Comment' },
    AtelierCurrent      = { link = prefer({ 'DiagnosticOk', 'String' }) },
    AtelierGlyph        = { link = prefer({ 'Delimiter', 'Special' }) },
    AtelierKey          = { link = 'Special' },
    AtelierStatusOk     = { link = 'DiagnosticOk' },
    AtelierStatusBusy   = { link = prefer({ 'DiagnosticWarn', 'DiagnosticInfo' }) },
    AtelierStatusErr    = { link = 'DiagnosticError' },
    AtelierStatusMissing = { link = 'Comment' },
    AtelierFilterPrompt = { link = prefer({ 'Operator', 'Special' }) },
    AtelierFilterCursor = { link = prefer({ 'Cursor', 'IncSearch' }) },
    AtelierCursorLine   = { link = 'CursorLine' },
  }

  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', def, { default = true }))
  end
end

return M
