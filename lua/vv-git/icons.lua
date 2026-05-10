-- 轻量图标查询：优先走 vv-icons (展开/空态增强)，次选 MiniIcons，最后 fallback
-- 不依赖 vv-explorer，保持 vv-git 独立

local M = {}

local DIR_OPEN  = { glyph = '󰝰', hl = 'VVGitPanelDir' }
local DIR_CLOSE = { glyph = '󰉋', hl = 'VVGitPanelDir' }
local FILE      = { glyph = '󰈔', hl = 'VVGitPanelFile' }

local has_vv_icons, vv_icons = pcall(require, 'vv-icons')

---@param node { name:string, is_dir:boolean, open:boolean, has_children?:boolean }
---@return string glyph, string? hl
function M.resolve(node)
  if node.is_dir then
    -- 1. 尝试从 vv-icons 获取增强图标（展开/空态）
    if has_vv_icons then
      local g, h, is_default = vv_icons.get('directory', node.name, {
        open = node.open,
        empty = node.has_children == false
      })
      if not is_default then
        -- 如果 hl 为空，说明是全局 fallback 图标，保持插件原色
        return g, h or 'VVGitPanelDir'
      end
      -- vv-icons 内部已处理 MiniIcons fallback，若仍是 default，跳过 MiniIcons 直接使用默认值
    else
      -- 2. 若 vv-icons 缺失，回退到标准 MiniIcons 逻辑
      local mi = _G.MiniIcons
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
    end

    -- 3. 插件默认值
    local d = node.open and DIR_OPEN or DIR_CLOSE
    return d.glyph, d.hl
  end

  -- 文件逻辑
  if has_vv_icons then
    local g, h, is_default = vv_icons.get('file', node.name)
    if not is_default then return g, h end
  else
    local mi = _G.MiniIcons
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
  end

  return FILE.glyph, FILE.hl
end

return M
