-- 渲染 diff 窗口的折叠行文案
-- 挂法：nvim_set_option_value('foldtext', "v:lua.require'vv-git.foldtext'.render()", { win = win })
-- 高亮：整行走 Folded 组 → 由 winhighlight 映射到 VVGitFold（跟随主题 Comment）

local M = {}

---@return string
function M.render()
  local count = vim.v.foldend - vim.v.foldstart + 1
  local noun = count == 1 and 'line' or 'lines'
  return string.format('  ⋯  %d %s unchanged', count, noun)
end

return M
