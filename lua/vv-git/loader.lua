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
    -- 无需各自轮询或等 FocusGained。消费者监听 `User VVGitStatusChanged`
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

    -- 清理过期的多选键：选择键（section:relpath）会跨渲染持久化，但树重建后某些路径
    -- 可能已变更分区或消失（如外部 git add 把 ?? 文件移入 staged）。若不剪枝，
    -- discard_selection/toggle_stage_selection 会按「当前树」重新分类一个已不在该分区
    -- 的路径，导致 untracked 文件被误路由到 git restore（no-op）、确认框漏掉删除警告
    -- 这里丢弃任何在新树对应分区里已不是 leaf 文件的选择键，让动作与所见保持一致
    if state.selection and next(state.selection) then
      for key in pairs(state.selection) do
        local section, relpath = key:match('^(.-):(.+)$')
        local side_root = section and state.tree[section]
        if not (side_root and Tree.leaf_at(side_root, relpath)) then
          state.selection[key] = nil
        end
      end
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
