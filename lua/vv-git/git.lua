-- git 命令封装：索引、show、stage/unstage/discard、commit
-- 异步优先，失败统一通过 notify 提示

local utils_git = require('vv-utils.git')
local Fs = require('vv-utils.fs')

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
    -- Fs.delete 递归处理目录/文件，路径已不存在时静默成功，失败抛错 → pcall 收集
    local ok, err = pcall(Fs.delete, abspath)
    if not ok then
      errors[#errors + 1] = p .. ': ' .. tostring(err)
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
      -- 导致 Neovim diff 视觉对齐异常 + 搜索匹配错位。统一归一化为 LF
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

-- 列出所有本地 + 远程分支
---@param root string
---@param cb fun(branches: string[]?, err?: string)
function M.branches(root, cb)
  vim.system(
    { 'git', '-C', root, 'branch', '-a', '--format=%(refname:short)' },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git branch failed'); return end
      local result = {}
      for _, l in ipairs(vim.split(vim.trim(r.stdout or ''), '\n', { plain = true })) do
        l = vim.trim(l)
        if l ~= '' then result[#result + 1] = l end
      end
      cb(result)
    end)
  )
end

-- 获取某 ref 的简短信息（用于冲突 diff winbar 标题）
---@param root string
---@param ref string  'HEAD' | 'MERGE_HEAD' | 任意 git ref
---@param cb fun(info: {hash:string, branch:string, subject:string}?)
function M.conflict_info(root, ref, cb)
  vim.system(
    { 'git', '-C', root, 'log', '-1', '--format=%h%x00%D%x00%s', ref },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil); return end
      local parts = vim.split(vim.trim(r.stdout or ''), '\0', { plain = true })
      local hash     = parts[1] or ''
      local refnames = parts[2] or ''
      local subject  = parts[3] or ''
      -- 从装饰串里提取最短可读分支名
      -- 可能格式：'HEAD -> branch-ours, branch-ours' / 'branch-theirs' / 'tag: v1.0, main'
      local branch = refnames:match('HEAD %-> ([^,]+)')
                  or refnames:match('^([^,%(]+)')
                  or ''
      cb({ hash = vim.trim(hash), branch = vim.trim(branch), subject = vim.trim(subject) })
    end)
  )
end

-- 列出某 ref 的最近 N 条 commit（格式：hash\x01short\x01subject）
---@param root string
---@param ref string
---@param n integer
---@param cb fun(commits: {hash:string, short:string, subject:string}[]?, err?: string)
function M.log(root, ref, n, cb)
  vim.system(
    { 'git', '-C', root, 'log', ref, '--pretty=format:%H\x01%h\x01%s', '-' .. (n or 50) },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git log failed'); return end
      local result = {}
      for _, line in ipairs(vim.split(vim.trim(r.stdout or ''), '\n', { plain = true })) do
        local hash, short, subject = line:match('^([^\x01]+)\x01([^\x01]+)\x01(.*)$')
        if hash then
          result[#result + 1] = { hash = vim.trim(hash), short = vim.trim(short), subject = subject or '' }
        end
      end
      cb(result)
    end)
  )
end

-- 获取两个 ref 之间的变更文件列表（git diff --name-status -z from..to）
-- -z 用 NUL 分隔字段：避免路径含 tab/换行，且 quotePath 不再转义非 ASCII（保持裸 UTF-8）
-- 字段序列：status\0 path\0；rename/copy 为 status\0 old\0 new\0（三个连续 NUL 字段）
---@param root string
---@param from_ref string
---@param to_ref string
---@param cb fun(files: {status:string, path:string, old_path?:string}[]?, err?: string)
function M.diff_names(root, from_ref, to_ref, cb)
  vim.system(
    { 'git', '-C', root, 'diff', '--name-status', '-z', from_ref .. '..' .. to_ref },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git diff failed'); return end
      local result = {}
      -- 末尾会多出一个空字段（最后一个 NUL 之后），按 status/path 配对消费即可忽略
      local fields = vim.split(r.stdout or '', '\0', { plain = true })
      local i = 1
      while i <= #fields do
        local status_raw = fields[i]
        if status_raw == '' then
          i = i + 1
        else
          -- status 形如 'M'、'A'、'R100'、'C75'；取首字母即类别
          local st = status_raw:sub(1, 1)
          if st == 'R' or st == 'C' then
            -- rename/copy：old=fields[i+1]、new=fields[i+2]
            local old_path = fields[i + 1]
            local new_path = fields[i + 2]
            if new_path and new_path ~= '' then
              result[#result + 1] = { status = st, path = new_path, old_path = old_path }
            end
            i = i + 3
          else
            local path = fields[i + 1]
            if path and path ~= '' then
              result[#result + 1] = { status = st, path = path }
            end
            i = i + 2
          end
        end
      end
      cb(result)
    end)
  )
end

---@param root string
---@param side_flag '--ours'|'--theirs'
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
local function accept_side(root, side_flag, paths, cb)
  if #paths == 0 then cb(true); return end
  run(root, vim.list_extend({ 'checkout', side_flag, '--' }, paths), function(ok, err)
    if not ok then cb(false, err); return end
    M.stage(root, paths, cb)
  end)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
function M.accept_ours(root, paths, cb) accept_side(root, '--ours', paths, cb) end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
function M.accept_theirs(root, paths, cb) accept_side(root, '--theirs', paths, cb) end

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

---@class VVGitWorktree
---@field path string  worktree 工作目录绝对路径（已 normalize）
---@field is_main boolean  是否为主 worktree（list 首条）
---@field head? string  当前 HEAD 的完整 sha
---@field branch? string  checkout 的分支短名；detached 时为 nil
---@field detached? boolean  是否处于 detached HEAD
---@field bare? boolean  是否为 bare 仓库（无工作树）
---@field locked? boolean  是否被 git 锁定
---@field prunable? boolean  工作目录已失效、可被 prune

-- 列出当前仓库的所有 worktree（git worktree list --porcelain）
-- porcelain 用空行分隔记录，每条形如：
--   worktree <abs-path>
--   HEAD <full-sha>
--   branch refs/heads/<name>   |   detached   |   bare
--   locked [reason]            （可选）
--   prunable [reason]          （可选）
-- 首条记录是主 worktree（is_main）
---@param root string
---@param cb fun(worktrees: VVGitWorktree[]?, err?: string)
function M.worktree_list(root, cb)
  vim.system(
    { 'git', '-C', root, 'worktree', 'list', '--porcelain' },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git worktree list failed'); return end

      local list = {}
      local cur = nil
      local function flush()
        if cur then list[#list + 1] = cur; cur = nil end
      end

      for _, line in ipairs(vim.split(r.stdout or '', '\n', { plain = true })) do
        if line == '' then
          flush()
        else
          -- 每行 'key value'；value 可空（detached / bare）
          local key, val = line:match('^(%S+)%s*(.*)$')
          if key == 'worktree' then
            flush()
            cur = { path = vim.fs.normalize(val), is_main = #list == 0 }
          elseif cur then
            if key == 'HEAD' then
              cur.head = val
            elseif key == 'branch' then
              cur.branch = (val:gsub('^refs/heads/', ''))
            elseif key == 'detached' then
              cur.detached = true
            elseif key == 'bare' then
              cur.bare = true
            elseif key == 'locked' then
              cur.locked = true
            elseif key == 'prunable' then
              cur.prunable = true
            end
          end
        end
      end
      flush()

      cb(list)
    end)
  )
end

-- 当前分支名；detached HEAD 时退回短 hash（`branch --show-current` 此时为空）；失败为 ''
---@param root string
---@param cb fun(branch: string)
function M.current_branch(root, cb)
  vim.system(
    { 'git', '-C', root, 'branch', '--show-current' },
    { text = true },
    vim.schedule_wrap(function(r)
      local b = (r.code == 0) and vim.trim(r.stdout or '') or ''
      if b ~= '' then cb(b); return end
      vim.system(
        { 'git', '-C', root, 'rev-parse', '--short', 'HEAD' },
        { text = true },
        vim.schedule_wrap(function(r2)
          cb((r2.code == 0) and vim.trim(r2.stdout or '') or '')
        end)
      )
    end)
  )
end

return M
