-- git 命令封装：索引、show、stage/unstage/discard、commit
-- 异步优先，失败统一通过 notify 提示

local utils_git = require('vv-utils.git')

local M = {}

---@param root string
---@param cb fun(index: UtilsGitIndex?)
function M.index(root, cb)
  -- untracked = 'all'：展开所有 untracked 目录到单文件，以便精准过滤嵌套 git 仓库
  -- ignored = false：vv-git 不使用 is_ignored，跳过 --ignored 扫描
  utils_git.index(root, cb, { untracked = 'all', ignored = false })
end

---@param xy string
---@return boolean
local function is_conflict(xy)
  if not xy then return false end
  local first = xy:sub(1, 1)
  local second = xy:sub(2, 2)
  -- both-added / both-deleted 两侧都不是 U，需单独判；其余冲突态都含 U
  return xy == 'AA' or xy == 'DD' or first == 'U' or second == 'U'
end

M.is_conflict = is_conflict

---@param xy string
---@return boolean staged, boolean unstaged
function M.classify(xy)
  if xy == '??' then return false, true end
  if is_conflict(xy) then return false, false end -- 冲突单独走
  local x = xy:sub(1, 1)
  local y = xy:sub(2, 2)
  return x ~= ' ', y ~= ' '
end

---@param root string
---@param args string[]  git 子命令及参数
---@param cb fun(ok:boolean, stderr?:string)
local function run(root, args, cb)
  vim.system(
    vim.list_extend({ 'git', '-C', root }, args),
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        cb(false, r.stderr or 'git failed')
      else
        cb(true)
      end
    end)
  )
end

-- paths 为空则短路；否则把 prefix_args 与 paths 拼好交给 run
---@param root string
---@param prefix_args string[]
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
local function run_paths(root, prefix_args, paths, cb)
  if #paths == 0 then cb(true); return end
  local args = vim.list_extend(vim.deepcopy(prefix_args), paths)
  run(root, args, cb)
end

---@param root string
---@param paths string[]  相对路径
---@param cb fun(ok:boolean, stderr?:string)
function M.stage(root, paths, cb)
  run_paths(root, { 'add', '--' }, paths, cb)
end

-- 相当于 git add -A（全量 stage，含删除/未跟踪），不接受 paths
---@param root string
---@param cb fun(ok:boolean, stderr?:string)
function M.stage_all(root, cb)
  run(root, { 'add', '-A' }, cb)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
function M.unstage(root, paths, cb)
  -- restore --staged 比 reset HEAD 更干净（git 2.23+）
  run_paths(root, { 'restore', '--staged', '--' }, paths, cb)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
function M.discard(root, paths, cb)
  -- 只恢复工作区（--worktree），不动 index
  run_paths(root, { 'restore', '--worktree', '--' }, paths, cb)
end

-- 删除未跟踪文件（git restore --worktree 对 untracked 无效，需直接删除）
---@param root string
---@param paths string[]  相对路径
---@param cb fun(ok:boolean, stderr?:string)
function M.discard_untracked(root, paths, cb)
  local errors = {}
  for _, p in ipairs(paths) do
    local abspath = root .. '/' .. p
    local stat = vim.uv.fs_stat(abspath)
    if stat then
      local ok, err
      if stat.type == 'directory' then
        ok, err = pcall(vim.fn.delete, abspath, 'rf')
      else
        ok, err = os.remove(abspath)
      end
      if not ok then
        errors[#errors + 1] = p .. ': ' .. (err or 'unknown error')
      end
    end
  end
  if #errors > 0 then
    cb(false, table.concat(errors, '\n'))
  else
    cb(true)
  end
end

---@param root string
---@param message string
---@param cb fun(ok:boolean, stderr?:string)
function M.commit(root, message, cb)
  -- 用 stdin 喂 message，规避 shell 转义问题
  vim.system(
    { 'git', '-C', root, 'commit', '-F', '-' },
    { text = true, stdin = message },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        cb(false, r.stderr or r.stdout or 'commit failed')
      else
        cb(true, r.stdout)
      end
    end)
  )
end

-- 取某 rev 版本的文件内容（用于 diff 左侧 a-buffer）
-- rev:
--   'HEAD'  → HEAD 版本
--   ':0'    → index 版本（staged 视图的"旧侧"对比 HEAD）
---@param root string
---@param rev string
---@param relpath string
---@param cb fun(lines: string[]?, err?: string)
function M.show(root, rev, relpath, cb)
  vim.system(
    { 'git', '-C', root, 'show', rev .. ':' .. relpath },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        cb(nil, r.stderr or 'git show failed')
        return
      end
      local text = r.stdout or ''
      -- Windows 保存的文件 git show 原样回 \r\n；split('\n') 后行尾会残留 \r
      -- 导致 Neovim diff 视觉对齐异常 + 搜索匹配错位。统一归一化为 LF。
      text = text:gsub('\r\n', '\n')
      -- 去掉末尾的 trailing newline 避免多一行空行
      if text:sub(-1) == '\n' then text = text:sub(1, -2) end
      cb(vim.split(text, '\n', { plain = true }))
    end)
  )
end

---@param root string
---@param sub 'push'|'pull'
---@param cb fun(ok:boolean, output?:string)
local function net_op(root, sub, cb)
  vim.system(
    { 'git', '-C', root, sub },
    { text = true },
    vim.schedule_wrap(function(r)
      local out = (r.stdout or '') .. (r.stderr or '')
      cb(r.code == 0, out ~= '' and out or nil)
    end)
  )
end

---@param root string
---@param cb fun(ok:boolean, output?:string)
function M.push(root, cb) net_op(root, 'push', cb) end

---@param root string
---@param cb fun(ok:boolean, output?:string)
function M.pull(root, cb) net_op(root, 'pull', cb) end

-- 是否有任何已 staged 的变更
---@param root string
---@param cb fun(has_staged: boolean)
function M.has_staged(root, cb)
  vim.system(
    { 'git', '-C', root, 'diff', '--cached', '--quiet' },
    { text = true },
    vim.schedule_wrap(function(r)
      -- --quiet：无变化退出 0，有变化退出 1
      cb(r.code == 1)
    end)
  )
end

-- 获取未推送的 commit 数量
---@param root string
---@param cb fun(count: integer)
function M.ahead_count(root, cb)
  vim.system(
    { 'git', '-C', root, 'rev-list', '--count', 'HEAD@{u}..HEAD' },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        cb(0)
      else
        local count = tonumber(vim.trim(r.stdout or '0')) or 0
        cb(count)
      end
    end)
  )
end

return M
