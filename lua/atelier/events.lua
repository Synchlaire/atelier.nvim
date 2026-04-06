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
  local list = self.listeners[event]
  if not list then return end
  -- Iterate over a snapshot so listeners may unsubscribe themselves safely.
  local snapshot = {}
  for i, cb in ipairs(list) do snapshot[i] = cb end
  for _, cb in ipairs(snapshot) do
    local ok, err = pcall(cb, ...)
    if not ok then
      vim.schedule(function()
        vim.notify('[atelier] listener error on ' .. event .. ': ' .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

return Bus
