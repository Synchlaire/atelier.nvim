-- Read/write a tiny JSON file recording the last loaded theme. All I/O goes
-- through vim.uv so the main loop never blocks. The persisted shape is:
--   { spec_name = "tokyonight", theme = "tokyonight-night", background = "dark" }
-- `background` is optional and only present when the user declared one or
-- toggled via `B`. Anything unrecognized is silently dropped on read.
--
local M = {}

local uv = vim.uv or vim.loop

---@param data_dir string
---@return string
local function path(data_dir)
  return vim.fs.joinpath(data_dir, 'state.json')
end

---@param data_dir string
local function ensure_dir(data_dir)
  -- mkdir -p; ignore "already exists".
  vim.fn.mkdir(data_dir, 'p')
end

---@param data_dir string
---@return atelier.Current
function M.read(data_dir)
  local p = path(data_dir)
  local fd = uv.fs_open(p, 'r', 438)
  if not fd then return { spec_name = nil, theme = nil } end
  local stat = uv.fs_fstat(fd)
  local raw = stat and uv.fs_read(fd, stat.size, 0) or ''
  uv.fs_close(fd)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= 'table' then
    return { spec_name = nil, theme = nil }
  end
  local bg = decoded.background
  if bg ~= 'dark' and bg ~= 'light' then bg = nil end
  return {
    spec_name = type(decoded.spec_name) == 'string' and decoded.spec_name or nil,
    theme = type(decoded.theme) == 'string' and decoded.theme or nil,
    background = bg,
  }
end

---@param data_dir string
---@param current atelier.Current
function M.write(data_dir, current)
  ensure_dir(data_dir)
  local payload = vim.json.encode({
    spec_name = current.spec_name,
    theme = current.theme,
    background = current.background,
  })
  -- Atomic-ish: write to a temp then rename so a crash mid-write can't leave
  -- a half-written state.json behind.
  local p = path(data_dir)
  local tmp = p .. '.tmp'
  local fd = uv.fs_open(tmp, 'w', 420)
  if not fd then return end
  uv.fs_write(fd, payload, 0)
  uv.fs_close(fd)
  uv.fs_rename(tmp, p)
end

return M
