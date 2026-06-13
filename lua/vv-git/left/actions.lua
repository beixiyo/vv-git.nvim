-- 左栏按键动作：stage / unstage / discard
-- 文件粒度：直接对单个 relpath 操作
-- 文件夹粒度：递归收集子树所有 leaf，批量 git 命令

local api = vim.api
local Git = require('vv-git.git')
local Tree = require('vv-git.tree')
local Loader = require('vv-git.loader')

local M = {}

---@param id table  panel id_by_line 项：{ section, node } 或 section_header
---@return 'staged'|'unstaged'|'conflicts'|nil side, string[]? paths
local function collect(state, id)
  if not id then return nil, nil end
  local side
  local paths
  if id.section_header then
    side = id.section_header
    paths = Tree.leaf_paths(state.tree[side])
  elseif id.node then
    side = id.section
    paths = id.node.is_dir and Tree.leaf_paths(id.node) or { id.node.relpath }
  end

  if not paths then return nil, nil end

  -- unstage rename 时需要把旧路径也带上，否则 git restore --staged 会遗漏旧路径的 deletion 状态
  -- stage 时不能带旧路径：旧文件已不存在，git add 会报 pathspec not found
  if side == 'staged' and state.index and state.index.rename_map then
    local old_paths = {}
    local prefix_len = #state.git_root + 2

    for _, p in ipairs(paths) do
      local abs = state.git_root .. '/' .. p
      local old_abs = state.index.rename_map[abs]

      if old_abs then
        local old_rel
        if old_abs:sub(1, #state.git_root + 1) == state.git_root .. '/' then
          old_rel = old_abs:sub(prefix_len)
        else
          old_rel = old_abs
        end
        old_paths[#old_paths + 1] = old_rel
      end
    end

    if #old_paths > 0 then
      vim.list_extend(paths, old_paths)
    end
  end

  return side, paths
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

-- 根据 id.section 自动 stage 或 unstage（单键 toggle）
---@param state table
---@param id table
function M.toggle_stage(state, id)
  local side, paths = collect(state, id)
  if not paths or #paths == 0 then return end
  local fn = side == 'staged' and Git.unstage or Git.stage
  local label = side == 'staged' and 'unstage' or 'stage'
  fn(state.git_root, paths, function(ok, err)
    if not ok then
      vim.notify('[vv-git] ' .. label .. ' failed: ' .. (err or ''), vim.log.levels.ERROR); return
    end
    refresh(state)
  end)
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
  local side, paths = collect(state, id)
  if not paths or #paths == 0 then return end

  -- staged 区：d = unstage（与 VSCode 行为一致），不做 discard
  if side == 'staged' then
    Git.unstage(state.git_root, paths, function(ok, err)
      if not ok then
        vim.notify('[vv-git] unstage failed: ' .. (err or ''), vim.log.levels.ERROR); return
      end
      refresh(state)
    end)
    return
  end

  -- unstaged 区：d = discard（弹确认框）
  local xy_map = {}
  if id.section_header then
    local root_node = state.tree[id.section_header]
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
    prompt_msg = prompt_msg
      .. string.format('\n⚠ %d untracked file(s) will be permanently deleted!', #untracked)
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

  local function do_discard_tracked(after)
    if #tracked == 0 then after(); return end
    Git.discard(state.git_root, tracked, function(ok, err)
      -- 失败也继续走 after()：否则链被掐断，untracked 不删、on_done 不刷新，
      -- 面板与磁盘（可能已部分 restore）不一致。与 discard_selection 的 discard_tracked 对齐
      if not ok then
        vim.notify('[vv-git] discard failed: ' .. (err or ''), vim.log.levels.ERROR)
      end
      after()
    end)
  end

  local function do_discard_untracked(after)
    if #untracked == 0 then after(); return end
    Git.discard_untracked(state.git_root, untracked, function(ok, err)
      if not ok then
        vim.notify('[vv-git] delete untracked failed: ' .. (err or ''), vim.log.levels.ERROR)
      end
      after()
    end)
  end

  do_discard_tracked(function()
    do_discard_untracked(on_done)
  end)
end

-- 多选批量 toggle_stage：staged → unstage，unstaged → stage，两组并发执行
---@param state table
---@param items {section:string, relpath:string}[]
function M.toggle_stage_selection(state, items)
  local staged, unstaged = {}, {}
  for _, item in ipairs(items) do
    if item.section == 'staged' then
      staged[#staged + 1] = item.relpath
    else
      unstaged[#unstaged + 1] = item.relpath
    end
  end

  -- staged 侧需要带上 rename 旧路径（与 collect() 逻辑一致）
  if #staged > 0 and state.index and state.index.rename_map then
    local extras = {}
    local prefix_len = #state.git_root + 2
    for _, p in ipairs(staged) do
      local abs = state.git_root .. '/' .. p
      local old_abs = state.index.rename_map[abs]
      if old_abs then
        local old_rel = old_abs:sub(1, #state.git_root + 1) == state.git_root .. '/'
            and old_abs:sub(prefix_len) or old_abs
        extras[#extras + 1] = old_rel
      end
    end
    vim.list_extend(staged, extras)
  end

  if not staged[1] and not unstaged[1] then return end

  local function do_unstage(after)
    if not staged[1] then after(); return end
    Git.unstage(state.git_root, staged, function(ok, err)
      if not ok then vim.notify('[vv-git] unstage failed: ' .. (err or ''), vim.log.levels.ERROR) end
      after()
    end)
  end

  local function do_stage(after)
    if not unstaged[1] then after(); return end
    Git.stage(state.git_root, unstaged, function(ok, err)
      if not ok then vim.notify('[vv-git] stage failed: ' .. (err or ''), vim.log.levels.ERROR) end
      after()
    end)
  end

  do_unstage(function()
    do_stage(function()
      Loader.reload_index(state)
    end)
  end)
end

-- 多选批量 discard：staged → unstage；unstaged → 弹一次确认框后 discard
---@param state table
---@param items {section:string, relpath:string}[]
function M.discard_selection(state, items)
  local staged, unstaged = {}, {}
  for _, item in ipairs(items) do
    if item.section == 'staged' then
      staged[#staged + 1] = item.relpath
    else
      unstaged[#unstaged + 1] = item.relpath
    end
  end

  local function do_staged(after)
    if not staged[1] then after(); return end
    Git.unstage(state.git_root, staged, function(ok, err)
      if not ok then vim.notify('[vv-git] unstage failed: ' .. (err or ''), vim.log.levels.ERROR) end
      after()
    end)
  end

  local function do_unstaged(after)
    if not unstaged[1] then after(); return end
    -- 判断是否含 untracked
    local xy_map = {}
    if state.tree and state.tree.unstaged then
      xy_map = collect_xy(state.tree.unstaged)
    end
    local untracked, tracked = split_by_tracked(unstaged, xy_map)
    local msg = string.format('Discard %d selected file(s)?', #unstaged)
    if #untracked > 0 then
      msg = msg .. string.format('\n⚠ %d untracked file(s) will be permanently deleted!', #untracked)
    end
    local choice = vim.fn.confirm(msg, '&Yes\n&No', 2)
    if choice ~= 1 then after(); return end

    local function discard_tracked(cb)
      if not tracked[1] then cb(); return end
      Git.discard(state.git_root, tracked, function(ok, err)
        if not ok then vim.notify('[vv-git] discard failed: ' .. (err or ''), vim.log.levels.ERROR) end
        cb()
      end)
    end
    local function discard_untracked(cb)
      if not untracked[1] then cb(); return end
      Git.discard_untracked(state.git_root, untracked, function(ok, err)
        if not ok then vim.notify('[vv-git] delete untracked failed: ' .. (err or ''), vim.log.levels.ERROR) end
        cb()
      end)
    end
    discard_tracked(function() discard_untracked(after) end)
  end

  do_staged(function()
    do_unstaged(function()
      Loader.reload_index(state)
    end)
  end)
end

---@param state table
---@param id table
---@param side_name 'ours'|'theirs'
local function accept_conflict_side(state, id, side_name)
  local section, paths = collect(state, id)
  -- 非冲突节点上按 < / >，或这次 accept 失败：都不会触发渲染，需主动清掉
  -- M._action 预设的 hint，否则它会在下次无关渲染（R / gitsigns / 保存）时错位光标
  if section ~= 'conflicts' or not paths or #paths == 0 then
    state._action_hint = nil
    return
  end
  Git['accept_' .. side_name](state.git_root, paths, function(ok, err)
    if not ok then
      vim.notify('[vv-git] accept ' .. side_name .. ' failed: ' .. (err or ''), vim.log.levels.ERROR)
      state._action_hint = nil
      return
    end
    reload_conflict_result(state)
    refresh(state)
  end)
end

---@param state table
---@param id table
function M.accept_ours(state, id) accept_conflict_side(state, id, 'ours') end

---@param state table
---@param id table
function M.accept_theirs(state, id) accept_conflict_side(state, id, 'theirs') end

-- 多选批量 accept_ours/accept_theirs：仅对 conflicts 区的选中项生效
---@param state table
---@param items {section:string, relpath:string}[]
---@param side_name 'ours'|'theirs'
local function accept_selection(state, items, side_name)
  local paths = {}
  for _, item in ipairs(items) do
    if item.section == 'conflicts' then
      paths[#paths + 1] = item.relpath
    end
  end
  -- 无 conflicts 选中项 / accept 失败：都不会触发渲染，需主动清掉 M._action 预设的
  -- hint，否则它会在下次无关渲染（R / gitsigns / 保存）时错位光标（与单选 accept 一致）
  if not paths[1] then
    state._action_hint = nil
    return
  end
  Git['accept_' .. side_name](state.git_root, paths, function(ok, err)
    if not ok then
      vim.notify('[vv-git] accept ' .. side_name .. ' failed: ' .. (err or ''), vim.log.levels.ERROR)
      state._action_hint = nil
      return
    end
    reload_conflict_result(state)
    refresh(state)
  end)
end

---@param state table
---@param items {section:string, relpath:string}[]
function M.accept_ours_selection(state, items) accept_selection(state, items, 'ours') end

---@param state table
---@param items {section:string, relpath:string}[]
function M.accept_theirs_selection(state, items) accept_selection(state, items, 'theirs') end

return M
