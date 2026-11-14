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

---@param hex integer
---@return number
local function luminance(hex)
  local function ch(shift)
    local c = bit.band(bit.rshift(hex, shift), 255) / 255
    return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * ch(16) + 0.7152 * ch(8) + 0.0722 * ch(0)
end

---@param a integer
---@param b integer
---@return number
local function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

---Background the picker text sits on (float bg, else Normal, else a
---background-based guess).
---@return integer
local function surface_bg()
  for _, name in ipairs({ 'NormalFloat', 'Normal' }) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl and hl.bg then return hl.bg end
  end
  return vim.o.background == 'light' and 0xffffff or 0x000000
end

---First candidate whose foreground reads on the picker surface (contrast
--->= 4.5), taken from the active colorscheme; otherwise plain float text.
---Metadata that fails this is indistinguishable from the background, so it
---falls back to the readable base instead of staying dim.
---@param candidates string[]
---@return string
local function readable(candidates)
  local bg = surface_bg()
  for _, name in ipairs(candidates) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl and hl.fg and contrast(hl.fg, bg) >= 4.5 then return name end
  end
  return 'NormalFloat'
end

local GROUP = 'AtelierHighlights'

function M.setup()
  -- `:colorscheme` runs `hi clear`, which drops every group below, so rebuild
  -- on ColorScheme. One augroup with clear = true: no duplicate listeners.
  vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = GROUP,
    callback = function() M.define() end,
  })
  M.define()
end

function M.define()
  local subtle = readable({ 'Comment', 'NonText', 'LineNr' })
  local groups = {
    AtelierNormal       = { link = 'NormalFloat' },
    AtelierBorder       = { link = 'FloatBorder' },
    AtelierTitle        = { link = prefer({ 'FloatTitle', 'Title' }) },
    AtelierSubtle       = { link = subtle },
    AtelierDivider      = { link = prefer({ 'WinSeparator', 'LineNr' }) },
    AtelierSpecHeader   = { link = prefer({ 'Function', 'Identifier' }) },
    AtelierTheme        = { link = 'Normal' },
    AtelierThemeBg      = { link = subtle },
    AtelierCurrent      = { link = prefer({ 'DiagnosticOk', 'String' }) },
    AtelierPreview      = { link = prefer({ 'DiagnosticInfo', 'Special' }) },
    AtelierGlyph        = { link = prefer({ 'Delimiter', 'Special' }) },
    AtelierKey          = { link = readable({ 'Special', 'Title', 'Function' }) },
    AtelierStatusOk     = { link = 'DiagnosticOk' },
    AtelierStatusBusy   = { link = prefer({ 'DiagnosticWarn', 'DiagnosticInfo' }) },
    AtelierStatusErr    = { link = 'DiagnosticError' },
    AtelierStatusMissing = { link = subtle },
    AtelierFilterPrompt = { link = prefer({ 'Operator', 'Special' }) },
    AtelierFilterCursor = { link = prefer({ 'Cursor', 'IncSearch' }) },
    AtelierCursorLine   = { link = 'CursorLine' },
    -- Control strip. Selection inverts; the preview draft also underlines
    -- and carries its own glyph, so state never relies on colour alone.
    AtelierControl      = { link = 'AtelierTheme' },
    AtelierControlActive = { reverse = true },
    -- Reverse (never a hard-coded colour) keeps the same contrast as the
    -- applied button on any colorscheme.
    AtelierControlDraft = { reverse = true, underline = true, bold = true },
  }

  for name, def in pairs(groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', def, { default = true }))
  end
end

return M
