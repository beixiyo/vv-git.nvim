-- 左栏按键动作：stage / unstage / discard / accept
-- 文件粒度：直接对单个 relpath 操作
-- 文件夹粒度：递归收集子树所有 leaf，批量 git 命令
-- 多仓库：每个节点经 id.root 路由到所属仓库（git -C <root>）；多选时按仓库分桶

local api = vim.api
local Git = require('vv-git.git')
local Tree = require('vv-git.tree')
local Loader = require('vv-git.loader')
local Subrepo = require('vv-git.subrepo')
local State = require('vv-git.state')

local M = {}

---@param state table
---@return VVGitIndexWriteOptions
local function current_write_opts(state)
  local owner_root = state.git_root
  return {
    is_current = function()
      return State.is_current(state) and not state._closing and state.git_root == owner_root
    end,
  }
end

-- 并发跑一组异步操作（每个 op 接收 done 回调），全部完成后调用 done（空组立即回调）
---@param ops fun(done:fun())[]
---@param done fun()
local function join(ops, done)
  if #ops == 0 then done(); return end
  local pending = #ops
  for _, op in ipairs(ops) do
    op(function()
      pending = pending - 1
      if pending == 0 then done() end
    end)
  end
end

-- 统一的失败提示
---@param label string  操作名（'stage' / 'unstage' / 'discard' / ...）
---@param err string?
local function notify_err(label, err)
  vim.notify('[vv-git] ' .. label .. ' failed: ' .. (err or ''), vim.log.levels.ERROR)
end

-- 把一个 git 操作包成 join() 可用的 op（接收 done）：失败只提示、仍调 done 不掐断链路
-- 注意：单键动作（toggle_stage / discard staged 分支）失败要「即返回、不刷新」，语义不同，
-- 不走本工厂、只复用 notify_err
---@param fn fun(root:string, paths:string[], cb:fun(ok:boolean, err:string?))
---@param root string
---@param paths string[]
---@param label string
---@return fun(done:fun())
local function git_op(fn, root, paths, label, opts)
  return function(done)
    fn(root, paths, function(ok, err)
      if not ok then notify_err(label, err) end
      done()
    end, opts)
  end
end

-- discard 确认框里的 untracked 永久删除告警（单/多选共用，保证文案一致）
---@param n integer
---@return string
local function untracked_warn(n)
  return string.format('\n⚠ %d untracked file(s) will be permanently deleted!', n)
end

-- 给某仓库的 staged 列表补上 rename 旧路径（就地扩展）：unstage rename 需带旧路径，
-- 否则 git restore --staged 会遗漏旧路径的 deletion 状态；stage 不能带（旧文件已不存在）
-- rename_map 的 key 为绝对路径
---@param repo table?  Subrepo.repo_of 结果（含 index.rename_map）
---@param root string
---@param staged string[]
local function append_rename_olds(repo, root, staged)
  local rmap = repo and repo.index and repo.index.rename_map
  if not rmap then return end
  local prefix_len = #root + 2
  local extras = {}
  for _, p in ipairs(staged) do
    local old_abs = rmap[root .. '/' .. p]
    if old_abs then
      extras[#extras + 1] = (old_abs:sub(1, #root + 1) == root .. '/') and old_abs:sub(prefix_len) or old_abs
    end
  end
  vim.list_extend(staged, extras)
end

---@param id table  panel id_by_line 项：{ section, base, root, node } 或 section_header
---@return 'staged'|'unstaged'|'conflicts'|nil base, string[]? paths, string? root
local function collect(state, id)
  if not id then return nil, nil, nil end
  local root = id.root or state.git_root
  local repo = Subrepo.repo_of(state, root)
  local side, paths
  if id.section_header then
    side = id.base
    paths = (repo and repo.tree and repo.tree[side]) and Tree.leaf_paths(repo.tree[side]) or {}
  elseif id.node then
    side = id.base
    paths = id.node.is_dir and Tree.leaf_paths(id.node) or { id.node.relpath }
  end

  if not paths then return nil, nil, nil end

  -- staged 侧带上 rename 旧路径（复用 repo，避免再查一次 repo_of）
  if side == 'staged' then append_rename_olds(repo, root, paths) end

  return side, paths, root
end

-- 接受冲突后强制重新加载 c_buf（worktree 已被 git checkout --ours/theirs 改写）
---@param state table
local function reload_conflict_result(state)
  local c_buf = state.view and state.view.c_buf
  if not c_buf or not api.nvim_buf_is_valid(c_buf) then return end
  pcall(api.nvim_buf_call, c_buf, function()
    vim.cmd('silent! edit!')
  end)
end

---@param state table
---@param after fun()?
local function refresh(state, after)
  Loader.reload_index(state, after)
end

-- 根据 id.base 自动 stage 或 unstage（单键 toggle）
---@param state table
---@param id table
---@param after fun()?
---@param settled fun(ok:boolean)?
function M.toggle_stage(state, id, after, settled)
  local side, paths, root = collect(state, id)
  if not paths or #paths == 0 then return end

  local owner_root = state.git_root
  local fn = side == 'staged' and Git.unstage or Git.stage
  local label = side == 'staged' and 'unstage' or 'stage'
  local hint = state._action_hint

  fn(root, paths, function(ok, err, idle)
    if not State.is_current(state) or state._closing or state.git_root ~= owner_root then return end

    if not ok then
      notify_err(label, err)
      if state._action_hint == hint then state._action_hint = nil end
    end

    -- 快速连按时，同仓库 writer queue 只由最后一项触发 reload；否则每完成一项
    -- 都会重画面板并让后续按键重新读取变化中的树
    if idle ~= false then
      refresh(state, function()
        if ok and after then after() end
        if settled then settled(ok) end
      end)
    end
  end, current_write_opts(state))
end

-- 收集节点下所有 leaf 的 xy 状态码
---@param node table
---@return table<string, string>  { relpath = xy }
local function collect_xy(node)
  local map = {}
  if not node.is_dir then
    if node.xy then map[node.relpath] = node.xy end
  else
    for _, c in pairs(node.children or {}) do
      for p, xy in pairs(collect_xy(c)) do
        map[p] = xy
      end
    end
  end
  return map
end

-- 按 xy 状态将路径列表分为 untracked（??）和 tracked 两组
---@param paths string[]
---@param xy_map table<string, string>
---@return string[] untracked, string[] tracked
local function split_by_tracked(paths, xy_map)
  local untracked, tracked = {}, {}
  for _, p in ipairs(paths) do
    if xy_map[p] == '??' then
      untracked[#untracked + 1] = p
    else
      tracked[#tracked + 1] = p
    end
  end
  return untracked, tracked
end

---@param state table
---@param id table
function M.discard(state, id)
  local side, paths, root = collect(state, id)
  if not paths or #paths == 0 then return end

  -- staged 区：d = unstage（与 VSCode 行为一致），不做 discard
  if side == 'staged' then
    Git.unstage(root, paths, function(ok, err)
      if not ok then notify_err('unstage', err); return end
      refresh(state)
    end, current_write_opts(state))
    return
  end

  -- unstaged 区：d = discard（弹确认框）
  local repo = Subrepo.repo_of(state, root)
  local xy_map = {}
  if id.section_header then
    local root_node = repo and repo.tree and repo.tree[id.base]
    if root_node then xy_map = collect_xy(root_node) end
  elseif id.node then
    xy_map = collect_xy(id.node)
  end

  local untracked, tracked = split_by_tracked(paths, xy_map)

  local prompt_msg
  if id.section_header then
    prompt_msg = string.format('Are you sure you want to discard ALL %d unstaged file(s)?', #paths)
  else
    local label = id.node.is_dir
        and string.format('directory %s (%d files)', id.node.relpath, #paths)
        or id.node.relpath
    prompt_msg = string.format('Are you sure you want to discard %s?', label)
  end

  if #untracked > 0 then
    prompt_msg = prompt_msg .. untracked_warn(#untracked)
  end

  local choice = vim.fn.confirm(prompt_msg, '&Yes\n&No', 2)
  if choice ~= 1 then
    -- 用户取消：清掉 M._action 预设的 hint，否则它会在下次无关渲染（R / gitsigns / 保存）时错位光标
    state._action_hint = nil
    return
  end

  local function on_done()
    refresh(state, function()
      local view = state.view
      if view and view.b_buf and vim.api.nvim_buf_is_valid(view.b_buf) then
        pcall(vim.api.nvim_buf_call, view.b_buf, function()
          vim.cmd('silent! checktime')
        end)
      end
    end)
  end

  -- tracked / untracked 各自一个 op，失败也继续（git_op 恒调 done）：否则链被掐断，
  -- 面板与磁盘（可能已部分 restore）不一致。与 discard_selection 的并发 discard 对齐
  local dops = {}
  if #tracked > 0 then dops[#dops + 1] = git_op(Git.discard, root, tracked, 'discard') end
  if #untracked > 0 then dops[#dops + 1] = git_op(Git.discard_untracked, root, untracked, 'delete untracked') end
  join(dops, on_done)
end

-- 把多选 items 按所属仓库分桶，每桶再分 staged / unstaged
---@param state table
---@param items {root:string, base:string, relpath:string}[]
---@return table<string, { staged:string[], unstaged:string[] }>
local function bucket_items(state, items)
  local buckets = {}
  for _, it in ipairs(items) do
    local root = it.root or state.git_root
    local b = buckets[root]
    if not b then b = { staged = {}, unstaged = {} }; buckets[root] = b end
    if it.base == 'staged' then
      b.staged[#b.staged + 1] = it.relpath
    else
      b.unstaged[#b.unstaged + 1] = it.relpath
    end
  end
  return buckets
end

-- 多选批量 toggle_stage：staged → unstage，unstaged → stage；按仓库分桶并发执行
---@param state table
---@param items {root:string, base:string, relpath:string}[]
function M.toggle_stage_selection(state, items)
  local buckets = bucket_items(state, items)
  local ops = {}
  for root, b in pairs(buckets) do
    if #b.staged > 0 then
      append_rename_olds(Subrepo.repo_of(state, root), root, b.staged)
      ops[#ops + 1] = git_op(Git.unstage, root, b.staged, 'unstage', current_write_opts(state))
    end
    if #b.unstaged > 0 then
      ops[#ops + 1] = git_op(Git.stage, root, b.unstaged, 'stage', current_write_opts(state))
    end
  end

  if #ops == 0 then return end
  join(ops, function() Loader.reload_index(state) end)
end

-- 多选批量 discard：staged → unstage；unstaged → 弹一次确认框后 discard（跨仓库统一确认）
---@param state table
---@param items {root:string, base:string, relpath:string}[]
function M.discard_selection(state, items)
  local buckets = bucket_items(state, items)

  -- 先对各仓库的 unstaged 分 untracked/tracked 并统计总数（确认框只弹一次）
  local total_unstaged, total_untracked = 0, 0
  for root, b in pairs(buckets) do
    if #b.unstaged > 0 then
      local repo = Subrepo.repo_of(state, root)
      local xy_map = (repo and repo.tree and repo.tree.unstaged) and collect_xy(repo.tree.unstaged) or {}
      b.untracked, b.tracked = split_by_tracked(b.unstaged, xy_map)
      total_unstaged = total_unstaged + #b.unstaged
      total_untracked = total_untracked + #b.untracked
    end
  end

  -- staged 侧 unstage（无需确认）
  local unstage_ops = {}
  for root, b in pairs(buckets) do
    if #b.staged > 0 then
      unstage_ops[#unstage_ops + 1] = git_op(Git.unstage, root, b.staged, 'unstage', current_write_opts(state))
    end
  end

  local function run_unstaged(after)
    if total_unstaged == 0 then after(); return end
    local msg = string.format('Discard %d selected file(s)?', total_unstaged)
    if total_untracked > 0 then
      msg = msg .. untracked_warn(total_untracked)
    end
    if vim.fn.confirm(msg, '&Yes\n&No', 2) ~= 1 then after(); return end

    local dops = {}
    for root, b in pairs(buckets) do
      if b.tracked and #b.tracked > 0 then
        dops[#dops + 1] = git_op(Git.discard, root, b.tracked, 'discard')
      end
      if b.untracked and #b.untracked > 0 then
        dops[#dops + 1] = git_op(Git.discard_untracked, root, b.untracked, 'delete untracked')
      end
    end
    join(dops, after)
  end

  join(unstage_ops, function() run_unstaged(function() Loader.reload_index(state) end) end)
end

---@param state table
---@param id table
---@param side_name 'ours'|'theirs'
local function accept_conflict_side(state, id, side_name)
  local section, paths, root = collect(state, id)
  -- 非冲突节点上按 < / >，或这次 accept 失败：都不会触发渲染，需主动清掉
  -- M._action 预设的 hint，否则它会在下次无关渲染（R / gitsigns / 保存）时错位光标
  if section ~= 'conflicts' or not paths or #paths == 0 then
    state._action_hint = nil
    return
  end
  Git['accept_' .. side_name](root, paths, function(ok, err)
    if not ok then
      notify_err('accept ' .. side_name, err)
      state._action_hint = nil
      return
    end
    reload_conflict_result(state)
    refresh(state)
  end, current_write_opts(state))
end

---@param state table
---@param id table
function M.accept_ours(state, id) accept_conflict_side(state, id, 'ours') end

---@param state table
---@param id table
function M.accept_theirs(state, id) accept_conflict_side(state, id, 'theirs') end

-- 多选批量 accept_ours/accept_theirs：仅对 conflicts 区的选中项生效，按仓库分桶
---@param state table
---@param items {root:string, base:string, relpath:string}[]
---@param side_name 'ours'|'theirs'
local function accept_selection(state, items, side_name)
  local buckets = {}
  for _, it in ipairs(items) do
    if it.base == 'conflicts' then
      local root = it.root or state.git_root
      buckets[root] = buckets[root] or {}
      buckets[root][#buckets[root] + 1] = it.relpath
    end
  end

  local ops = {}
  for root, paths in pairs(buckets) do
    ops[#ops + 1] = git_op(
      Git['accept_' .. side_name], root, paths, 'accept ' .. side_name, current_write_opts(state)
    )
  end

  -- 无 conflicts 选中项 / accept 失败：都不会触发渲染，需主动清掉 M._action 预设的
  -- hint，否则它会在下次无关渲染（R / gitsigns / 保存）时错位光标（与单选 accept 一致）
  if #ops == 0 then
    state._action_hint = nil
    return
  end
  join(ops, function()
    reload_conflict_result(state)
    refresh(state)
  end)
end

---@param state table
---@param items {root:string, base:string, relpath:string}[]
function M.accept_ours_selection(state, items) accept_selection(state, items, 'ours') end

---@param state table
---@param items {root:string, base:string, relpath:string}[]
function M.accept_theirs_selection(state, items) accept_selection(state, items, 'theirs') end

return M
