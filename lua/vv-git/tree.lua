-- 变更文件虚拟树：基于 git status 相对路径构建两个 trie（staged / unstaged）
--
-- Node:
--   name          - 本层文件名/目录名
--   relpath       - 相对 git_root 的路径（前缀唯一标识节点）
--   is_dir        - bool
--   children      - { [name] = Node } (仅 dir)
--   xy            - 原始 porcelain 状态码（仅 leaf file）
--   letter        - 展示用状态字母（A/M/D/R/?/!）

local Git = require('vv-git.git')

local M = {}

---@param xy string
---@param side 'staged'|'unstaged'
---@return string letter
local function status_letter(xy, side)
  if xy == '??' then return '?' end
  if Git.is_conflict(xy) then return '!' end
  local c = side == 'staged' and xy:sub(1, 1) or xy:sub(2, 2)
  if c == ' ' then return 'M' end
  return c
end

---@param xy string
---@param side 'staged'|'unstaged'
---@return string hl_group  (VVGit*，由 vv-utils.git.register_hl 注册)
local function status_hl(xy, side)
  local letter = status_letter(xy, side)
  return ({
    ['A'] = 'VVGitAdded',
    ['M'] = 'VVGitModified',
    ['D'] = 'VVGitDeleted',
    ['R'] = 'VVGitRenamed',
    ['C'] = 'VVGitRenamed',
    ['?'] = 'VVGitUntracked',
    ['!'] = 'VVGitConflict',
  })[letter] or 'VVGitModified'
end

---@param name string
---@param relpath string
---@param is_dir boolean
local function make_node(name, relpath, is_dir)
  return {
    name = name,
    relpath = relpath,
    is_dir = is_dir,
    children = is_dir and {} or nil,
  }
end

---@param root table
---@param relpath string
---@param xy string
---@param side 'staged'|'unstaged'
local function insert(root, relpath, xy, side)
  local parts = vim.split(relpath, '/', { plain = true })
  local cur = root
  local accum = ''
  for i, part in ipairs(parts) do
    accum = accum == '' and part or (accum .. '/' .. part)
    local is_last = (i == #parts)
    cur.children[part] = cur.children[part] or make_node(part, accum, not is_last)
    local node = cur.children[part]
    if is_last then
      node.xy = xy
      node.letter = status_letter(xy, side)
      node.hl = status_hl(xy, side)
    end
    cur = node
  end
end

local function new_root() return { name = '', relpath = '', is_dir = true, children = {} } end
M.new_root = new_root

---@param status_map table<string,string>
---@param git_root string
---@return { staged: table, unstaged: table, conflicts: table }
function M.build(status_map, git_root)
  local staged = new_root()
  local unstaged = new_root()
  local conflicts = new_root()

  local prefix_len = #git_root + 2 -- '/' + 1
  for abspath, xy in pairs(status_map) do
    -- abspath 形如 /repo/src/foo.ts，取 src/foo.ts
    local relpath
    if abspath:sub(1, #git_root + 1) == git_root .. '/' then
      relpath = abspath:sub(prefix_len)
    else
      relpath = abspath
    end
    if relpath == '' then goto continue end

    -- 忽略嵌套的 git 仓库（同 VSCode 行为：不对未跟踪的子仓库进行状态展示）
    if xy == '??' then
      local stat = vim.uv.fs_stat(abspath)
      if stat and stat.type == 'directory' then
        if vim.uv.fs_stat(abspath .. '/.git') then
          goto continue
        end
      end
    end

    if Git.is_conflict(xy) then
      insert(conflicts, relpath, xy, 'unstaged')
    else
      local is_staged, is_unstaged = Git.classify(xy)
      if is_staged then insert(staged, relpath, xy, 'staged') end
      if is_unstaged then insert(unstaged, relpath, xy, 'unstaged') end
    end

    ::continue::
  end

  return { staged = staged, unstaged = unstaged, conflicts = conflicts }
end

---@param node table
---@return table[]  按"目录优先 + 名字字典序"排序
local function children_sorted(node)
  local list = {}
  for _, c in pairs(node.children or {}) do list[#list + 1] = c end
  table.sort(list, function(a, b)
    if a.is_dir ~= b.is_dir then return a.is_dir end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

-- 扁平化：folds[relpath]=true 表示该目录"已折叠"；默认全部展开
---@param side_root table
---@param folds table<string,boolean>
---@param opts? { group_empty_dirs?: boolean }
---@return table[] rows  { node, depth, display_name, has_children }
function M.flatten(side_root, folds, opts)
  opts = opts or {}
  local rows = {}

  local function walk(parent, depth)
    for _, child in ipairs(children_sorted(parent)) do
      local chain = { child.name }
      local tip = child
      local subs = tip.is_dir and children_sorted(tip) or {}

      if tip.is_dir and opts.group_empty_dirs ~= false then
        -- 单链 dir 折叠显示：src/foo/bar/ 合成一行
        while #subs == 1 and subs[1].is_dir do
          chain[#chain + 1] = subs[1].name
          tip = subs[1]
          subs = children_sorted(tip)
        end
      end

      local has_children = #subs > 0
      rows[#rows + 1] = {
        node = tip,
        depth = depth,
        display_name = #chain > 1 and table.concat(chain, '/') or child.name,
        has_children = has_children,
      }

      if tip.is_dir and has_children and not folds[tip.relpath] then
        walk(tip, depth + 1)
      end
    end
  end

  walk(side_root, 0)
  return rows
end

---@param node table
---@return integer
function M.count_files(node)
  if not node.is_dir then return 1 end
  local n = 0
  for _, c in pairs(node.children or {}) do n = n + M.count_files(c) end
  return n
end

-- 聚合子树内 leaf file 的状态分布，供目录节点的属性预览使用
---@param node table
---@return { total: integer, letters: table<string, integer> }
function M.count_status(node)
  local result = { total = 0, letters = {} }

  local function walk(cur)
    if not cur.is_dir then
      result.total = result.total + 1
      local letter = cur.letter or 'M'
      result.letters[letter] = (result.letters[letter] or 0) + 1
      return
    end

    for _, child in pairs(cur.children or {}) do walk(child) end
  end

  walk(node)
  return result
end

---@param node table
---@param out? string[]
---@return string[] relpaths  子树下所有 leaf file
function M.leaf_paths(node, out)
  out = out or {}
  if not node.is_dir then
    out[#out + 1] = node.relpath
  else
    for _, c in pairs(node.children or {}) do M.leaf_paths(c, out) end
  end
  return out
end

-- 按 relpath 在树中定位 leaf file 节点（用于校验某个选择键是否仍存在于新树）
---@param side_root table
---@param relpath string
---@return table? leaf  命中且为 leaf file 才返回；目录/不存在返回 nil
function M.leaf_at(side_root, relpath)
  if not side_root or relpath == '' then return nil end
  local cur = side_root
  for _, part in ipairs(vim.split(relpath, '/', { plain = true })) do
    cur = cur.children and cur.children[part]
    if not cur then return nil end
  end
  return (not cur.is_dir) and cur or nil
end

-- 从 compare 文件列表构建树（复用内部 trie 逻辑）
---@param files { status:string, path:string, old_path?:string }[]
---@return table root  与 M.build 返回的 side_root 同构
function M.build_compare(files)
  local root = new_root()
  for _, f in ipairs(files) do
    local parts = vim.split(f.path, '/', { plain = true })
    local cur = root
    local accum = ''
    for i, part in ipairs(parts) do
      accum = accum == '' and part or (accum .. '/' .. part)
      local is_last = (i == #parts)
      cur.children[part] = cur.children[part] or make_node(part, accum, not is_last)
      local node = cur.children[part]
      if is_last then
        local st = f.status
        node.letter = st
        node.hl = ({
          A = 'VVGitAdded', M = 'VVGitModified', D = 'VVGitDeleted',
          R = 'VVGitRenamed', C = 'VVGitAdded',
        })[st] or 'VVGitModified'
        node.xy = st .. ' '
        node.compare_status = st
        node.old_relpath = f.old_path
      end
      cur = node
    end
  end
  return root
end

-- 是否 root 完全为空
---@param side_root table
function M.empty(side_root)
  return not side_root.children or next(side_root.children) == nil
end

return M
