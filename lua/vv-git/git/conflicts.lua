-- Git 冲突解决：接受 ours/theirs 后写回 index

local Operations = require('vv-git.git.operations')
local M = {}

local function accept_side(root, side_flag, paths, cb, opts)
  if #paths == 0 then cb(true); return end
  Operations._queue_index_write(root, function(done)
    Operations._run(root, vim.list_extend({ 'checkout', side_flag, '--' }, paths), function(ok, err)
      if not ok then done(false, err); return end
      Operations._run_paths(root, { 'add', '--' }, paths, done)
    end)
  end, cb, opts)
end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
---@param opts? VVGitIndexWriteOptions
function M.accept_ours(root, paths, cb, opts) accept_side(root, '--ours', paths, cb, opts) end

---@param root string
---@param paths string[]
---@param cb fun(ok:boolean, stderr?:string)
---@param opts? VVGitIndexWriteOptions
function M.accept_theirs(root, paths, cb, opts) accept_side(root, '--theirs', paths, cb, opts) end

return M
