-- 左侧树导航的纯计算：筛选、排序并返回目标条目，不读取或修改运行时状态

local M = {}

---@class VVGitNavigationEntry
---@field lnum integer
---@field id table

---@param id_by_line table<integer, table>
---@param predicate? fun(id:table):boolean
---@return VVGitNavigationEntry[]
local function entries(id_by_line, predicate)
  local result = {}
  for lnum, id in pairs(id_by_line or {}) do
    if not predicate or predicate(id) then
      result[#result + 1] = { lnum = lnum, id = id }
    end
  end
  table.sort(result, function(a, b) return a.lnum < b.lnum end)
  return result
end

---@param id_by_line table<integer, table>
---@param current_lnum integer
---@param direction 1|-1
---@param predicate? fun(id:table):boolean
---@return VVGitNavigationEntry?
function M.move(id_by_line, current_lnum, direction, predicate)
  local candidates = entries(id_by_line, predicate)
  if #candidates == 0 then return nil end

  if direction > 0 then
    for _, entry in ipairs(candidates) do
      if entry.lnum > current_lnum then return entry end
    end
    return candidates[1]
  end

  for i = #candidates, 1, -1 do
    if candidates[i].lnum < current_lnum then return candidates[i] end
  end
  return candidates[#candidates]
end

---@param id_by_line table<integer, table>
---@param edge 'first'|'last'
---@param predicate? fun(id:table):boolean
---@return VVGitNavigationEntry?
function M.edge(id_by_line, edge, predicate)
  local candidates = entries(id_by_line, predicate)
  if #candidates == 0 then return nil end
  return edge == 'first' and candidates[1] or candidates[#candidates]
end

return M
