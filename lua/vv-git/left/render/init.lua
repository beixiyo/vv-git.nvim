-- 左栏渲染入口：组合内容构建与 buffer 刷新，保持原 require 路径

local Builder = require('vv-git.left.render.builder')
local Flush = require('vv-git.left.render.flush')

local M = {
  ns = vim.api.nvim_create_namespace('vv-git-panel'),
  build = Builder.build,
}

---@param state table
---@param passive boolean?
function M.render(state, passive)
  return Flush.render(state, passive, M.build, M.ns)
end

return M
