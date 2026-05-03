-- 轻量图标查询：只走 MiniIcons（可用则用），不用则 fallback 默认字符
-- 不依赖 vv-explorer，保持 vv-git 独立

local M = {}

local DIR_OPEN  = { glyph = '', hl = 'VVGitPanelDir' }
local DIR_CLOSE = { glyph = '', hl = 'VVGitPanelDir' }
local FILE      = { glyph = '', hl = 'VVGitPanelFile' }

---@param node { name:string, is_dir:boolean, open:boolean }
---@return string glyph, string? hl
function M.resolve(node)
  local mi = _G.MiniIcons
  if node.is_dir then
    if mi then
      local g, h, is_default = mi.get('directory', node.name)
      if not is_default then return g, h end
      local lower = node.name:lower()
      if lower ~= node.name then
        local g2, h2, d2 = mi.get('directory', lower)
        if not d2 then return g2, h2 end
      end
      return g, h
    end
    local d = node.open and DIR_OPEN or DIR_CLOSE
    return d.glyph, d.hl
  end
  if mi then
    local g, h, is_default = mi.get('file', node.name)
    if not is_default then return g, h end
    local lower = node.name:lower()
    if lower ~= node.name then
      local g2, h2, d2 = mi.get('file', lower)
      if not d2 then return g2, h2 end
    end
    return g, h
  end
  return FILE.glyph, FILE.hl
end

return M
