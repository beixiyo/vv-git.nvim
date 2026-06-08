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
    -- 广播 git 状态变更：stage/unstage/discard/commit/push/conflict 等所有变更操作
    -- 都汇聚到 reload_index（actions → refresh、commit/push → M.refresh），故这里发一个
    -- User 事件，让 vv-explorer / vv-statuscol 等外部消费者即时刷新自己的 git 索引，
    -- 无需各自轮询或等 FocusGained。消费者监听 `User VVGitStatusChanged`。
    vim.api.nvim_exec_autocmds('User', {
      pattern = 'VVGitStatusChanged',
      modeline = false,
      data = { root = state.git_root },
    })
    if after then after() end
  end

  Git.index(state.git_root, function(idx)
    state.index = idx
    if idx then
      state.tree = Tree.build(idx.status_map, state.git_root)
    else
      state.tree = { staged = Tree.new_root(), unstaged = Tree.new_root(), conflicts = Tree.new_root() }
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
