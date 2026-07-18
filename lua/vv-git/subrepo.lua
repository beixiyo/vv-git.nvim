-- 子仓库（嵌套 git 仓库 / submodule）扫描与多仓库寻址
--
-- 设计要点：
--   * git status 默认不递归进嵌套仓库——父仓库只把子仓库整体报成一条折叠条目，
--     拿不到其内部文件。故对发现的每个子仓库**单独**跑一次 `git -C <子仓库> status`，
--     每个仓库各建一棵独立的变更树，在左栏作为独立的「Sub-Repo」块渲染
--   * 发现走文件系统递归找 `.git`（目录=独立仓库、文件=linked worktree / submodule），限深 +
--     prune（node_modules 等）避免性能爆炸；submodule status / .gitmodules 只覆盖
--     已注册的 submodule，看不到未注册的独立嵌套仓库，故不采用
--   * linked worktree（本仓库另一份 checkout）默认不当子仓库——靠 vv-utils.git_dir_kind
--     按 `.git` 文件的 gitdir 路径识别（`/worktrees/`），与目录名/布局无关；可用
--     subrepo.scan_worktrees 开回
--   * 块隔离：fold / selection / section_folds 的 key 都按仓库前缀（root\0section），
--     同名文件在不同仓库间互不串状态；操作路由直接用节点所属仓库根（`git -C <root>`）

local uv = vim.uv or vim.loop
local UGit = require('vv-utils.git')

local function norm(p) return vim.fs.normalize(p) end

local M = {}

--- 限深递归发现 root 下的嵌套 git 仓库
--- 命中含 `.git`（目录或文件）的目录即记为子仓库根，并在 depth 允许范围内继续下钻，
--- 以覆盖「仓库里再嵌套仓库」。只处理真实目录（跳过符号链接，避免环）
--- 被父仓库 gitignore 的目录整个跳过（不记录、不下钻）——与「忽略文件不显示」一致，
--- 避免在 build/ 这类被忽略目录里翻出 vendored 仓库造成噪音
---@param root string  父仓库根（绝对路径）
---@param depth integer  目录递归最大深度（root 直接子目录为 1）；<= 0 不扫描
---@param prune table<string, boolean>  跳过的目录名集合（建议含 node_modules / .git）
---@param ignored table<string, boolean>?  被忽略的目录绝对路径集合（来自父仓库 gitignore），命中即跳过
---@param scan_worktrees boolean?  是否把 linked worktree 也当子仓库（默认 false：worktree 是本仓库
---  另一份 checkout，渲染成块只是重复噪音，故跳过；submodule / 真·独立嵌套仓库不受影响照常发现）
---@return string[] subroots  子仓库根绝对路径（已规范化），不含 root 自身
function M.discover(root, depth, prune, ignored, scan_worktrees)
  local subroots = {}
  if not root or root == '' or not depth or depth <= 0 then return subroots end
  root = norm(root)
  prune = prune or {}

  local function walk(dir, level)
    local fd = uv.fs_scandir(dir)
    if not fd then return end

    while true do
      local name, typ = uv.fs_scandir_next(fd)
      if not name then break end

      if typ == nil then
        -- scandir 未提供类型时回退 lstat（不跟随符号链接）：与快路径里符号链接被报成
        -- 'link' 而跳过的行为一致，避免目录符号链接被当真实目录递归而成环/越界
        local st = uv.fs_lstat(dir .. '/' .. name)
        typ = st and st.type or nil
      end

      if typ == 'directory' and not prune[name] then
        local child = dir .. '/' .. name
        local nchild = norm(child)

        if not (ignored and ignored[nchild]) then
          if uv.fs_stat(child .. '/.git') then
            -- worktree 默认排除（同仓库另一份 checkout，非外部仓库）；submodule / 真仓库保留
            if scan_worktrees or UGit.git_dir_kind(child) ~= 'worktree' then
              subroots[#subroots + 1] = nchild
            end
          end

          if level < depth then
            walk(child, level + 1)
          end
        end
      end
    end
  end

  walk(root, 1)
  return subroots
end

-- ── 多仓库寻址：section id / selection key / 仓库查找 ──────────────────────
--
-- section id 约定：父仓库用裸 base（'staged'/'unstaged'/'conflicts'/'compare'），
-- 子仓库用 `<root>\0<base>`。fold / selection / section_folds 的 key（形如
-- `<section_id>\0<relpath>`）天然按仓库隔离，父仓库的 key 与改造前等价
--
-- 分隔符统一用 NUL：仓库根路径、base、relpath 都不可能含 NUL，故任意含特殊字符
-- （含 ':'、空格等）的根路径或文件名都能无歧义 round-trip。所有 key 的拼/拆都必须
-- 走本模块的 section_id / sel_key / split_key / parse_* 函数，不要在别处手写分隔符

--- 构造 section id：父仓库返回裸 base，子仓库返回 `root\0base`
---@param root string?  节点所属仓库根（nil 或等于父根 → 父仓库）
---@param parent_root string
---@param base string  'staged'|'unstaged'|'conflicts'
---@return string
function M.section_id(root, parent_root, base)
  if not root or root == parent_root then return base end
  return root .. '\0' .. base
end

--- 拆解 section id → root（nil 表示父仓库）, base
---@param sid string
---@return string? root, string base
function M.parse_section_id(sid)
  local root, base = sid:match('^(.-)%z(.+)$')
  if base then return root, base end
  return nil, sid
end

--- 构造 selection / fold key：`<section_id>\0<relpath>`
---@param section_id string  Subrepo.section_id() 的产物（裸 base 或 root\0base）
---@param relpath string
---@return string
function M.sel_key(section_id, relpath)
  return section_id .. '\0' .. relpath
end

--- 拆 key → section_id, relpath（按最后一个 NUL 切；section_id 自身可含 NUL）
---@param key string
---@return string? section_id, string? relpath
function M.split_key(key)
  return key:match('^(.*)%z(.*)$')
end

--- 拆解 selection / fold key → root（nil 表示父仓库）, base, relpath
---@param key string
---@return string? root, string? base, string? relpath
function M.parse_sel_key(key)
  local sid, relpath = M.split_key(key)
  if not sid then return nil end
  local root, base = M.parse_section_id(sid)
  return root, base, relpath
end

--- 按仓库根取出对应的 repo 视图（父仓库或某个子仓库）：{ root, tree, index }
---@param state table
---@param root string?  nil / 父根 → 父仓库
---@return table?  { root, tree, index, label? }
function M.repo_of(state, root)
  if not root or root == state.git_root then
    return { root = state.git_root, tree = state.tree, index = state.index, repo_info = state.repo_info }
  end
  for _, sr in ipairs(state.subrepos or {}) do
    if sr.root == root then return sr end
  end
  return nil
end

return M
