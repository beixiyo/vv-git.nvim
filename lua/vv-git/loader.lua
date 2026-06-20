-- 索引加载：调 git 拿 status → 构建 tree → 渲染左栏
-- 抽出此层避免 init.lua ↔ actions.lua 经 M._reload_index 绕回来的循环依赖

local Git = require('vv-git.git')
local Tree = require('vv-git.tree')
local LeftRender = require('vv-git.left.render')
local Subrepo = require('vv-git.subrepo')
local UGit = require('vv-utils.git')

local M = {}

-- 由 config.subrepo.prune（数组）构造跳过的目录名集合（.git 始终跳过）
---@param cfg table
---@return table<string, boolean>
local function build_pruneset(cfg)
  local p = { ['.git'] = true }
  for _, name in ipairs(cfg.prune or {}) do p[name] = true end
  return p
end

-- 剔除「指向子仓库根」的折叠条目（父仓库的 `?? sub/`、子仓库里的 ` M deeper` 等都靠它过滤）
---@param status_map table<string, string>?
---@param is_subroot table<string, boolean>
---@return table<string, string>
local function strip_subroots(status_map, is_subroot)
  local m = {}
  for abs, xy in pairs(status_map or {}) do
    if not is_subroot[abs] then m[abs] = xy end
  end
  return m
end

-- 统一父/子仓库 index 表形状：{ status_map, rename_map }（调用方只读 rename_map，
-- status_map 一并带上让父子结构一致，避免后续按节点仓库读 repo.index.status_map 时父子不对称）
---@param status_map table<string, string>
---@param rename_map table?
---@return table
local function make_repo_index(status_map, rename_map)
  return { status_map = status_map, rename_map = rename_map or {} }
end

-- 父仓库：用自身 status（剔除子仓库根折叠条目）建 index + tree，就地写入 state
---@param state table
---@param pidx table?  父仓库 Git.index 结果
---@param is_subroot table<string, boolean>
---@param branch string?  当前分支名
local function build_parent_repo(state, pidx, is_subroot, branch)
  local pmap = strip_subroots(pidx and pidx.status_map, is_subroot)
  state.index = make_repo_index(pmap, pidx and pidx.rename_map)
  state.tree = Tree.build(pmap, state.git_root)
  state.branch = branch
end

-- 子仓库块：各建一棵独立树（路径相对其自身根，故 git 操作直接 `git -C <root>`），
-- 同样剔除指向更深层子仓库的折叠条目
---@param state table
---@param subroots string[]
---@param indexes table<string, table>
---@param is_subroot table<string, boolean>
---@param branches table<string, string>  root → 分支名
local function build_subrepos(state, subroots, indexes, is_subroot, branches)
  state.subrepos = {}
  for _, sr in ipairs(subroots) do
    local idx = indexes[sr]
    local smap = strip_subroots(idx and idx.status_map, is_subroot)
    state.subrepos[#state.subrepos + 1] = {
      root = sr,
      label = sr:sub(#state.git_root + 2), -- 相对父根：'nested' / 'nested/deep'
      branch = branches[sr],
      tree = Tree.build(smap, sr),
      index = make_repo_index(smap, idx and idx.rename_map),
    }
  end
end

-- 清理过期的多选键：选择键（section_id\0relpath）跨渲染持久化，但树重建后某些路径可能已
-- 变更分区或消失（如外部 git add 把 ?? 文件移入 staged）。若不剪枝，
-- discard_selection/toggle_stage_selection 会按「当前树」重新分类一个已不在该分区的路径，
-- 导致 untracked 文件被误路由到 git restore（no-op）、确认框漏掉删除警告。
-- 按 key 里的仓库前缀定位到对应仓库的树，丢弃已不是 leaf 文件的选择键
---@param state table
local function prune_selection(state)
  if not (state.selection and next(state.selection)) then return end
  for key in pairs(state.selection) do
    local root, section, relpath = Subrepo.parse_sel_key(key)
    local repo = section and Subrepo.repo_of(state, root)
    local side_root = repo and repo.tree and repo.tree[section]
    if not (side_root and Tree.leaf_at(side_root, relpath)) then
      state.selection[key] = nil
    end
  end
end

---@param state table
---@param after fun()?
---@param passive boolean?  被动刷新（auto_refresh / 保存 / gitsigns / R / commit-push）：
---  render 保持光标停在当前文件、不按可能滞后的 cur_path 拉走（防 j/k 导航期光标拉扯）
function M.reload_index(state, after, passive)
  local done_index = false
  local done_ahead = false

  local function finalize()
    if not done_index or not done_ahead then return end
    LeftRender.render(state, passive)
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

  -- ahead_count 与子仓库发现/索引无依赖，先并行发起
  Git.ahead_count(state.git_root, function(count)
    state.ahead_count = count
    done_ahead = true
    finalize()
  end)

  -- 多仓库：父仓库 + 发现的子仓库各跑一次 git status，counter join 后各建一棵独立树。
  -- 父仓库剔除「指向子仓库根」的折叠条目（?? sub/ 或 M sub），改由子仓库自己的块呈现
  ---@param subroots string[]
  local function proceed(subroots)
    table.sort(subroots) -- 字典序：子仓库与其更深嵌套相邻，块顺序稳定

    local roots_to_index = { state.git_root }
    for _, r in ipairs(subroots) do roots_to_index[#roots_to_index + 1] = r end

    local is_subroot = {}
    for _, r in ipairs(subroots) do is_subroot[r] = true end

    -- 每个仓库各取一次 status 与分支名，全部到齐后统一建树（counter join）
    local indexes, branches = {}, {}
    local pending = #roots_to_index * 2

    local function on_part_done()
      pending = pending - 1
      if pending > 0 then return end

      build_parent_repo(state, indexes[state.git_root], is_subroot, branches[state.git_root])
      build_subrepos(state, subroots, indexes, is_subroot, branches)
      prune_selection(state)

      done_index = true
      finalize()
    end

    for _, r in ipairs(roots_to_index) do
      Git.index(r, function(idx)
        indexes[r] = idx
        on_part_done()
      end)
      Git.current_branch(r, function(br)
        branches[r] = br
        on_part_done()
      end)
    end
  end

  -- 子仓库扫描深度/配置由 lifecycle 在 open 时以闭包注入 state._subrepo（见该处注释），
  -- 数据层不反向 require 顶层 init，依赖方向保持自顶向下
  local sub = state._subrepo
  local depth = (sub and sub.depth()) or 0
  if not (depth and depth > 0) then
    proceed({})
    return
  end

  local cfg = (sub and sub.config()) or {}
  local prune = build_pruneset(cfg)

  if cfg.respect_gitignore then
    -- 可选：跳过被父仓库 gitignore 的目录。先拿忽略目录集合（快路径
    -- ls-files --others --ignored --directory）再据此过滤发现。
    -- 默认关闭——HOME-as-repo 场景 ~ 几乎忽略一切，开了会把所有子仓库都屏蔽掉
    UGit.ignored_entries(state.git_root, function(_, ignored_dirs)
      proceed(Subrepo.discover(state.git_root, depth, prune, ignored_dirs or {}))
    end)
  else
    proceed(Subrepo.discover(state.git_root, depth, prune))
  end
end

return M
