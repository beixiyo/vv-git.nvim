-- Git linked worktree 查询与管理

local Operations = require('vv-git.git.operations')
local M = {}

---@class VVGitWorktree
---@field path string
---@field is_main boolean
---@field head? string
---@field branch? string
---@field detached? boolean
---@field bare? boolean
---@field locked? boolean
---@field prunable? boolean

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

---@param root string
---@param opts { path:string, base:string, branch?:string }
---@param cb fun(ok:boolean, stderr?:string)
function M.worktree_add(root, opts, cb)
  local args = { 'worktree', 'add' }
  if opts.branch and opts.branch ~= '' then vim.list_extend(args, { '-b', opts.branch }) end
  vim.list_extend(args, { opts.path, opts.base })
  Operations._run(root, args, cb)
end

---@param root string
---@param path string
---@param opts? { force?:boolean }
---@param cb fun(ok:boolean, stderr?:string)
function M.worktree_remove(root, path, opts, cb)
  local args = { 'worktree', 'remove' }
  if opts and opts.force then args[#args + 1] = '--force' end
  args[#args + 1] = path
  Operations._run(root, args, cb)
end

---@param path string
---@param cb fun(dirty:boolean?, stderr?:string)
function M.worktree_dirty(path, cb)
  vim.system(
    { 'git', '-C', path, 'status', '--porcelain', '--untracked-files=normal' },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then cb(nil, r.stderr or 'git status failed') else cb((r.stdout or '') ~= '') end
    end)
  )
end

return M
