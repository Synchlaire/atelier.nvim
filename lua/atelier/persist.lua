-- Small synchronous state I/O, bounded on read and atomically replaced on
-- write. Host events update only the effective-result cache; previews never write.
local M = {}
local uv = vim.uv or vim.loop
local MAX_BYTES = 65536

local function path(data_dir)
  return vim.fs.joinpath(data_dir, 'state.json')
end

local function background(value)
  if value == 'dark' or value == 'light' then return value end
end

function M.read(data_dir)
  local fd = uv.fs_open(path(data_dir), 'r', 438)
  if not fd then return {} end
  local stat = uv.fs_fstat(fd)
  local raw = stat and stat.size <= MAX_BYTES and uv.fs_read(fd, stat.size, 0) or ''
  uv.fs_close(fd)
  local ok, decoded = pcall(vim.json.decode, raw or '')
  if not ok or type(decoded) ~= 'table' then return {} end
  local bg = background(decoded.background)
  local mode = decoded.mode
  if mode ~= 'auto' and mode ~= 'dark' and mode ~= 'light' then mode = nil end
  return {
    spec_name = type(decoded.spec_name) == 'string' and decoded.spec_name ~= '' and decoded.spec_name or nil,
    theme = type(decoded.theme) == 'string' and decoded.theme ~= '' and decoded.theme or nil,
    choice = type(decoded.choice) == 'string' and decoded.choice ~= '' and decoded.choice or nil,
    background = bg,
    mode = mode,
  }
end

---@return boolean, string?
function M.write(data_dir, current)
  local ok, err = pcall(vim.fn.mkdir, data_dir, 'p')
  if not ok then return false, tostring(err) end
  local payload = vim.json.encode({
    version = 2,
    spec_name = current.spec_name,
    theme = current.theme,
    choice = current.choice,
    background = current.background,
    mode = current.mode,
  })
  local p = path(data_dir)
  local fd, tmp = uv.fs_mkstemp(p .. '.XXXXXX')
  if not fd then return false, tostring(tmp) end
  local written, write_err = uv.fs_write(fd, payload, 0)
  local closed, close_err = uv.fs_close(fd)
  if written ~= #payload or not closed then
    uv.fs_unlink(tmp)
    return false, tostring(write_err or close_err or 'incomplete state write')
  end
  local renamed, rename_err = uv.fs_rename(tmp, p)
  if not renamed then
    uv.fs_unlink(tmp)
    return false, tostring(rename_err)
  end
  return true
end

return M
