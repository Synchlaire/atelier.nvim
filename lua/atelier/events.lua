-- Tiny pub/sub bus. One bus per State; no module-level globals.
--
---@class atelier.Bus
---@field private listeners table<string, fun(...)[]>
local Bus = {}
Bus.__index = Bus

---@return atelier.Bus
function Bus.new()
  return setmetatable({ listeners = {} }, Bus)
end

---@param event string
---@param cb fun(...)
function Bus:on(event, cb)
  local list = self.listeners[event]
  if not list then
    list = {}
    self.listeners[event] = list
  end
  list[#list + 1] = cb
end

---@param event string
---@param cb fun(...)
function Bus:off(event, cb)
  local list = self.listeners[event]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == cb then
      table.remove(list, i)
    end
  end
end

---@param event string
function Bus:emit(event, ...)
  -- Listeners freely call nvim_* APIs (window:render touches the buffer),
  -- which is illegal inside a fast event context (vim.system callbacks,
  -- vim.uv timers, libuv I/O). When we detect we're in one, hop to the
  -- main loop via vim.schedule before dispatching. Outside fast context
  -- we stay synchronous so tests can assert on emit order without races.
  if vim.in_fast_event and vim.in_fast_event() then
    local args = { ... }
    local n = select('#', ...)
    vim.schedule(function() self:_dispatch(event, n, args) end)
  else
    self:_dispatch(event, select('#', ...), { ... })
  end
end

---@param event string
---@param n integer
---@param args table
function Bus:_dispatch(event, n, args)
  local list = self.listeners[event]
  if not list then return end
  -- Iterate over a snapshot so listeners may unsubscribe themselves safely.
  local snapshot = {}
  for i, cb in ipairs(list) do snapshot[i] = cb end
  for _, cb in ipairs(snapshot) do
    local ok, err = pcall(cb, unpack(args, 1, n))
    if not ok then
      vim.schedule(function()
        vim.notify('[atelier] listener error on ' .. event .. ': ' .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

return Bus
