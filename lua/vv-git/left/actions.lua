-- 左栏按键动作：stage / unstage / discard
-- 文件粒度：直接对单个 relpath 操作
-- 文件夹粒度：递归收集子树所有 leaf，批量 git 命令

local Git = require('vv-git.git')
local Tree = require('vv-git.tree')
local Loader = require('vv-git.loader')

local M = {}

---@param id table  panel id_by_line 项：{ section, node } 或 section_header
---@return 'staged'|'unstaged'|nil side, string[]? paths
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

  -- 如果要处理的路径中包含 rename 的新路径，把旧路径也带上
  -- 否则 git restore --staged 会遗漏对旧路径的 restore，导致旧路径的 deletion 状态残留
  if state.index and state.index.rename_map then
    local old_paths = {}
    local prefix_len = #state.git_root + 2

    for _, p in ipairs(paths) do
      local abs = state.git_root .. '/' .. p
      local old_abs = state.index.rename_map[abs]

      if old_abs then
        local old_rel
        if old_abs:sub(1, #state.git_root) == state.git_root then
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

  -- 收集每个路径对应的 xy 状态
  local xy_map = {}
  if id.section_header then
    local root_node = state.tree[id.section_header]
    if root_node then xy_map = collect_xy(root_node) end
  elseif id.node then
    xy_map = collect_xy(id.node)
  end

  local untracked, tracked = split_by_tracked(paths, xy_map)
  local has_untracked = #untracked > 0

  local is_staged = side == 'staged'
  local prompt_msg
  if id.section_header then
    prompt_msg = is_staged
      and string.format('Are you sure you want to unstage and discard ALL %d staged file(s)?', #paths)
      or string.format('Are you sure you want to discard ALL %d unstaged file(s)?', #paths)
  else
    local label = id.node.is_dir
        and string.format('directory %s (%d files)', id.node.relpath, #paths)
        or id.node.relpath
    prompt_msg = is_staged
        and string.format('Are you sure you want to unstage and discard %s?', label)
        or string.format('Are you sure you want to discard %s?', label)
  end

  -- 未跟踪文件无法通过 git 恢复，追加警告
  if has_untracked then
    prompt_msg = prompt_msg
      .. string.format('\n⚠ %d untracked file(s) will be permanently deleted!', #untracked)
  end

  vim.ui.select({ 'Discard', 'Cancel' }, {
    prompt = prompt_msg,
  }, function(choice)
    if choice ~= 'Discard' then return end

    local function on_done()
      refresh(state, function()
        -- 如果 discard 的文件正在 b_win 显示，reload buffer
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
        if not ok then
          vim.notify('[vv-git] discard failed: ' .. (err or ''), vim.log.levels.ERROR); return
        end
        after()
      end)
    end

    local function do_discard_untracked(after)
      if #untracked == 0 then after(); return end
      Git.discard_untracked(state.git_root, untracked, function(ok, err)
        if not ok then
          vim.notify('[vv-git] delete untracked failed: ' .. (err or ''), vim.log.levels.ERROR); return
        end
        after()
      end)
    end

    local function do_discard_all()
      do_discard_tracked(function()
        do_discard_untracked(on_done)
      end)
    end

    if is_staged then
      Git.unstage(state.git_root, paths, function(ok, err)
        if not ok then
          vim.notify('[vv-git] unstage failed: ' .. (err or ''), vim.log.levels.ERROR); return
        end
        do_discard_all()
      end)
    else
      do_discard_all()
    end
  end)
end

return M
