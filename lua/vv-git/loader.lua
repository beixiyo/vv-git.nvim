-- 索引加载：调 git 拿 status → 构建 tree → 渲染左栏
-- 抽出此层避免 init.lua ↔ actions.lua 经 M._reload_index 绕回来的循环依赖

local Git = require('vv-git.git')
local Tree = require('vv-git.tree')
local LeftRender = require('vv-git.left.render')

local M = {}

---@param state table
---@param after fun()?
function M.reload_index(state, after)
  local done_index = false
  local done_ahead = false

  local function finalize()
    if not done_index or not done_ahead then return end
    LeftRender.render(state)
    if after then after() end
  end

  Git.index(state.git_root, function(idx)
    state.index = idx
    if idx then
      state.tree = Tree.build(idx.status_map, state.git_root)
    else
      state.tree = { staged = {children={}}, unstaged = {children={}}, conflicts = {children={}} }
    end
    done_index = true
    finalize()
  end)

  Git.ahead_count(state.git_root, function(count)
    state.ahead_count = count
    done_ahead = true
    finalize()
  end)
end

return M
