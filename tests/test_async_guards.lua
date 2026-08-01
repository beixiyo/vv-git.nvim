-- Async context guards: stale compare/show work must not survive a root or lifecycle change

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Compare = require('vv-git.compare')
local Git = require('vv-git.git')
local RightView = require('vv-git.right.view')
local State = require('vv-git.state')
local Worktree = require('vv-git.worktree')

State.clear()
local state = State.create()
state.git_root = '/old-root'

local original_diff_names = Git.diff_names
local pending
Git.diff_names = function(_, _, _, cb) pending = cb end

local completed = false
Compare.start_refs(state, 'HEAD~1', 'HEAD', 'HEAD~1', 'old compare', function()
  completed = true
end)
Compare.stop(state)
pending({ { status = 'M', path = 'old.txt' } })
assert(not completed and state.compare == nil, 'stopped compare ignores its late callback')

Compare.start_refs(state, 'HEAD~1', 'HEAD', 'HEAD~1', 'old root compare', function()
  completed = true
end)
state.git_root = '/new-root'
pending({ { status = 'M', path = 'old.txt' } })
assert(not completed and state.compare == nil, 'compare callback cannot cross a root change')

Git.diff_names = original_diff_names

state.view = nil
state._show_req_id = 7
RightView.close(state)
assert(state._show_req_id == 8, 'closing without an attached view invalidates pending shows')

-- Worktree manager 只允许最新一次 refresh 写回。
local original_worktree_list = Git.worktree_list
local pending_lists = {}
local list_calls = 0
Git.worktree_list = function(_, cb)
  list_calls = list_calls + 1
  if list_calls == 1 then
    cb({ { path = '/repo', branch = 'main', is_main = true } })
  else
    pending_lists[#pending_lists + 1] = cb
  end
end
Worktree.open_manager({ git_root = '/repo' }, function() end)
vim.api.nvim_feedkeys('rr', 'x', false)
assert(#pending_lists == 2, 'two refresh requests are in flight')
pending_lists[2]({
  { path = '/repo', branch = 'main', is_main = true },
  { path = '/repo/.worktrees/new', branch = 'feature/new' },
})
pending_lists[1]({ { path = '/repo', branch = 'main', is_main = true } })
local manager_buf = vim.api.nvim_get_current_buf()
assert(#vim.api.nvim_buf_get_lines(manager_buf, 0, -1, false) == 2, 'older refresh cannot overwrite the latest list')
vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
Git.worktree_list = original_worktree_list

State.clear()
print('vv-git async context guards: PASS')
