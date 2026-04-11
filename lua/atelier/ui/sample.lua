-- Fixture code sample shown in the preview pane. The buffer's filetype is
-- set to `lua` so treesitter + the active colorscheme highlight it with
-- the same groups the user's real files get. Covers a broad set of
-- syntactic categories (keywords, functions, strings, numbers, comments,
-- operators, constants, booleans) so no hl group hides in a corner.
--
local M = {}

M.lines = {
  '-- atelier preview · lua',
  'local atelier = require("atelier")',
  '',
  'local THEMES = {',
  '  "tokyonight-night",',
  '  "kanagawa-wave",',
  '  "rose-pine-moon",',
  '}',
  '',
  '---@param name string',
  '---@return boolean',
  'local function activate(name)',
  '  if not name or name == "" then',
  '    return false',
  '  end',
  '  local ok, err = pcall(vim.cmd.colorscheme, name)',
  '  if not ok then',
  '    vim.notify("failed: " .. err, vim.log.levels.ERROR)',
  '    return false',
  '  end',
  '  return true -- committed',
  'end',
  '',
  'for i, theme in ipairs(THEMES) do',
  '  local n = i * 2 + 0x10',
  '  print(string.format("[%02d] %s", n, theme))',
  'end',
  '',
  'atelier.on("state_changed", function()',
  '  -- react to theme changes',
  'end)',
}

return M
