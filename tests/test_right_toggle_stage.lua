-- 右侧 diff 连续 stage/unstage 的集成回归：
-- 防止延迟到达的布局回调用旧 view 覆盖下一文件，导致第二次 `-` 操作错误目标

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local function mapping(buf, lhs)
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if item.lhs == lhs then return item.callback end
  end
end

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, 'p')

local function git(args)
  local command = { 'git', '-C', repo }
  vim.list_extend(command, args)
  local output = vim.fn.system(command)
  assert(vim.v.shell_error == 0, output)
  return output
end

git({ 'init', '-q' })
git({ 'config', 'user.name', 'vv-git test' })
git({ 'config', 'user.email', 'test@example.com' })
vim.fn.writefile({ 'a1' }, repo .. '/a.txt')
vim.fn.writefile({ 'b1' }, repo .. '/b.txt')
git({ 'add', 'a.txt', 'b.txt' })
git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'a2' }, repo .. '/a.txt')
vim.fn.writefile({ 'b2' }, repo .. '/b.txt')
git({ 'add', 'a.txt', 'b.txt' })

local Plugin = require('vv-git')
local State = require('vv-git.state')
local Tree = require('vv-git.tree')
local RightView = require('vv-git.right.view')

Plugin.setup({
  preview = true,
  preview_debounce_ms = 0,
  auto_refresh = false,
})

local ready
local open_error
assert(Plugin.open({
  root = repo,
  path = 'a.txt',
  on_ready = function() ready = true end,
  on_error = function(err) open_error = err end,
}))
assert(vim.wait(3000, function() return ready end), open_error or 'repository did not open')

local state = State.get()
local first = Tree.leaf_at(state.tree.staged, 'a.txt')
assert(first, 'staged a.txt node is missing')
RightView.show(state, first, 'staged', false, state.git_root)
assert(vim.wait(3000, function()
  return state.view and state.view.path == 'a.txt'
end), 'a.txt diff did not open')

local first_win = state.view.a_win or state.view.b_win
local first_buf = vim.api.nvim_win_get_buf(first_win)
vim.api.nvim_set_current_win(first_win)
assert(mapping(first_buf, '-'), 'first diff buffer has no stage mapping')()

assert(vim.wait(3000, function()
  return state.view and state.view.path == 'b.txt' and state.view.section == 'staged'
end), 'first toggle did not keep the next staged diff as the current view')

local second_win = state.view.a_win or state.view.b_win
local second_buf = vim.api.nvim_win_get_buf(second_win)
vim.api.nvim_set_current_win(second_win)
assert(mapping(second_buf, '-'), 'second diff buffer has no stage mapping')()

assert(vim.wait(3000, function()
  local tree = state.tree
  if not tree then return false end
  return Tree.leaf_at(tree.unstaged, 'a.txt') ~= nil
    and Tree.leaf_at(tree.unstaged, 'b.txt') ~= nil
end), 'second toggle did not move the file shown by the current diff to unstaged')

local status = git({ 'status', '--short' })
assert(
  status:find(' M a.txt', 1, true) and status:find(' M b.txt', 1, true),
  'both files must be unstaged after two toggles:\n' .. status
)

Plugin.close()
vim.fn.delete(repo, 'rf')
print('vv-git right toggle stage: PASS')
