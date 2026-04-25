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
      local g, h = mi.get('directory', node.name)
      if g then return g, h end
    end
    local d = node.open and DIR_OPEN or DIR_CLOSE
    return d.glyph, d.hl
  end
  if mi then
    local g, h = mi.get('file', node.name)
    if g then return g, h end
  end
  return FILE.glyph, FILE.hl
end

return M
