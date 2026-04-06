-- Inline filter mode. When the user presses `/`, we enter a small read-key
-- loop that mutates `state.ui.filter` on each printable keystroke and asks
-- the window to re-render. This blocks the main loop while the user types
-- (same as input() / getcharstr() everywhere else in nvim) — the picker is
-- modal anyway so that's fine.
--
local M = {}

-- Keys that *commit* the filter and return to normal picker mode.
local COMMIT_KEYS = {
  ['\r'] = true,           -- <CR>
  ['\n'] = true,
}

-- Keys that *cancel* the filter (clears it).
local CANCEL_KEYS = {
  ['\27'] = true,          -- <Esc>
  [vim.api.nvim_replace_termcodes('<C-c>', true, false, true)] = true,
}

local BACKSPACE = {
  ['\8'] = true,
  ['\127'] = true,
  [vim.api.nvim_replace_termcodes('<BS>', true, false, true)] = true,
}

---Run the filter loop until the user commits or cancels. Returns true if
---the filter was committed (kept), false if cancelled (cleared).
---@param state atelier.State
---@param window atelier.Window
---@return boolean committed
function M.run(state, window)
  state.ui.mode = 'filter'
  window:render()
  -- Force the cursor onto the filter row so the user has visual confirmation.
  for i, row in ipairs(window.rows) do
    if row.kind == 'filter' then
      pcall(vim.api.nvim_win_set_cursor, window.win, { i, #state.ui.filter + 3 })
      break
    end
  end
  vim.cmd('redraw')

  local committed = true

  while true do
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == '' then
      committed = false
      break
    end

    if COMMIT_KEYS[ch] then
      break
    elseif CANCEL_KEYS[ch] then
      state.ui.filter = ''
      committed = false
      break
    elseif BACKSPACE[ch] then
      if #state.ui.filter > 0 then
        state.ui.filter = state.ui.filter:sub(1, -2)
      end
    elseif #ch == 1 and ch:byte() >= 32 and ch:byte() < 127 then
      state.ui.filter = state.ui.filter .. ch:lower()
    end
    -- Ignore everything else (arrow keys, function keys, etc.)

    window:render()
    -- Move the cursor onto the first matching theme row so the user can
    -- press <CR> immediately after committing the filter.
    for i, row in ipairs(window.rows) do
      if row.kind == 'filter' then
        pcall(vim.api.nvim_win_set_cursor, window.win, { i, #state.ui.filter + 3 })
        break
      end
    end
    vim.cmd('redraw')
  end

  state.ui.mode = 'normal'
  window:render()

  -- After committing, drop the cursor onto the first matching theme.
  if committed and state.ui.filter ~= '' then
    for i, row in ipairs(window.rows) do
      if row.kind == 'theme' then
        pcall(vim.api.nvim_win_set_cursor, window.win, { i, 8 })
        break
      end
    end
  end

  return committed
end

return M
