-- 右侧 diff `-` 的目标回归：
-- 右侧 `-` 只能操作当前 diff buffer 里可见的文件，绝不落到用户看不见的邻居上
-- 1. 飞行中连按被去重，不会顺手把下一个文件也切掉
-- 2. 首个 toggle 未完成时导航到别的文件，再按 `-` 必须操作导航到的那个文件

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
vim.fn.writefile({ 'c1' }, repo .. '/c.txt')
git({ 'add', 'a.txt', 'b.txt', 'c.txt' })
git({ 'commit', '-qm', 'initial' })
vim.fn.writefile({ 'a2' }, repo .. '/a.txt')
vim.fn.writefile({ 'b2' }, repo .. '/b.txt')
vim.fn.writefile({ 'c2' }, repo .. '/c.txt')
git({ 'add', 'a.txt', 'b.txt', 'c.txt' })

local Plugin = require('vv-git')
local State = require('vv-git.state')
local Tree = require('vv-git.tree')
local RightView = require('vv-git.right.view')
local Git = require('vv-git.git')
local Loader = require('vv-git.loader')

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
assert(vim.wait(3000, function() return ready end), open_error or '仓库未打开')

local state = State.get()
local first = Tree.leaf_at(state.tree.staged, 'a.txt')
assert(first, '未找到 staged a.txt 节点')
RightView.show(state, first, 'staged', false, state.git_root)
assert(vim.wait(3000, function()
  return state.view and state.view.path == 'a.txt'
end), 'a.txt diff 未打开')

-- 1. 飞行中连按：两次都只能命中屏幕上的 a.txt，第二次被 in-flight 去重
local first_win = state.view.a_win or state.view.b_win
local first_buf = vim.api.nvim_win_get_buf(first_win)
vim.api.nvim_set_current_win(first_win)
local rapid_toggle = assert(mapping(first_buf, '-'), 'diff 缓冲区未设置 stage 映射')
local unstage_calls = {}
local original_unstage = Git.unstage
Git.unstage = function(root_arg, paths, callback, opts)
  unstage_calls[#unstage_calls + 1] = vim.deepcopy(paths)
  return original_unstage(root_arg, paths, callback, opts)
end
rapid_toggle()
rapid_toggle()

local rapid_done = vim.wait(3000, function()
  local tree = state.tree
  if not tree then return false end
  return Tree.leaf_at(tree.unstaged, 'a.txt') ~= nil
end)
Git.unstage = original_unstage
assert(
  unstage_calls[1] and unstage_calls[1][1] == 'a.txt' and not unstage_calls[2],
  '右侧连按只能命中可见的 a.txt，第二次应被 in-flight 去重: ' .. vim.inspect(unstage_calls)
)
assert(rapid_done, '连按未把 a.txt 设置为 unstaged:\n' .. git({ 'status', '--short' }))

assert(vim.wait(3000, function()
  return state.view and state.view.path == 'b.txt' and state.view.section == 'staged'
end), 'git 完成后右侧应推进到原 section 的下一个文件')

local status = git({ 'status', '--short' })
assert(
  status:find(' M a.txt', 1, true) and not status:find(' M b.txt', 1, true),
  '第二次按键不应把不可见的 b.txt 也 unstage:\n' .. status
)

-- 2. reload 被 newer request 覆盖时不会执行 after；in-flight 必须仍由 Git action
-- 的 settled 释放，否则当前可见文件的 `-` 会从此被永久忽略
local original_reload_index = Loader.reload_index
local skipped_reload_count = 0
local settlement_calls = {}
Git.unstage = function(_, paths, callback)
  settlement_calls[#settlement_calls + 1] = vim.deepcopy(paths)
  callback(true, nil, true)
end
Loader.reload_index = function()
  skipped_reload_count = skipped_reload_count + 1
  -- 模拟 latest-wins：旧 reload 的 after 不执行
end

vim.api.nvim_set_current_win(state.view.b_win)
local settlement_toggle = assert(mapping(state.view.b_buf, '-'), '释放回归未设置 stage 映射')
settlement_toggle()
settlement_toggle()

Git.unstage = original_unstage
Loader.reload_index = original_reload_index
assert(
  settlement_calls[1] and settlement_calls[1][1] == 'b.txt'
    and settlement_calls[2] and settlement_calls[2][1] == 'b.txt',
  'reload after 被跳过后，同一可见文件应能再次触发: ' .. vim.inspect(settlement_calls)
)
assert(skipped_reload_count == 2, '两次 Git action 都应各自发起 reload')
assert(not next(state._view_stage_inflight or {}), 'reload after 被跳过后不应残留 in-flight key')
assert(
  state.view and state.view.path == 'b.txt' and state.view.section == 'staged',
  'reload after 未执行时测试前提应保持在可见的 staged b.txt'
)
state._action_hint = nil

-- 3. 导航回归：a.txt 的 toggle 还没完成就导航到 c.txt，再按 `-` 必须操作 c.txt
git({ 'add', 'a.txt' })
Plugin.refresh()
assert(vim.wait(3000, function()
  return state.tree and Tree.leaf_at(state.tree.staged, 'a.txt') ~= nil
end), '重新 stage a.txt 后索引未刷新')

local staged_a = Tree.leaf_at(state.tree.staged, 'a.txt')
RightView.show(state, staged_a, 'staged', false, state.git_root)
assert(vim.wait(3000, function()
  return state.view and state.view.path == 'a.txt' and state.view.section == 'staged'
end), '导航回归未打开 staged a.txt')

-- 挂起 git 回调，让 a.txt 的 toggle 一直停在飞行中
local nav_calls = {}
local pending_unstage
Git.unstage = function(_, paths, callback)
  nav_calls[#nav_calls + 1] = vim.deepcopy(paths)
  pending_unstage = callback
end

local nav_buf = state.view.b_buf
vim.api.nvim_set_current_win(state.view.b_win)
assert(mapping(nav_buf, '-'), '导航回归未设置 stage 映射')()

local staged_a_lnum
for lnum, panel_id in pairs(state.panel.id_by_line) do
  if panel_id.node and panel_id.node.relpath == 'a.txt' and panel_id.base == 'staged' then
    staged_a_lnum = lnum
    break
  end
end
assert(staged_a_lnum, '导航回归找不到 staged a.txt 行')
vim.api.nvim_win_set_cursor(state.panel.win, { staged_a_lnum, 0 })

vim.api.nvim_set_current_win(state.view.b_win)
local navigate_next = assert(mapping(nav_buf, '<C-J>'), '导航回归未设置下一文件映射')
navigate_next()
navigate_next()
assert(vim.wait(3000, function()
  return state.view and state.view.path == 'c.txt'
end), '导航回归未到达 c.txt')

vim.api.nvim_set_current_win(state.view.b_win)
assert(mapping(state.view.b_buf, '-'), '导航后的 diff 缓冲区未设置 stage 映射')()
assert(
  nav_calls[1] and nav_calls[1][1] == 'a.txt' and nav_calls[2] and nav_calls[2][1] == 'c.txt',
  '导航后 `-` 应操作可见的 c.txt，而不是残留的邻居 b.txt: ' .. vim.inspect(nav_calls)
)

Git.unstage = original_unstage
if pending_unstage then pending_unstage(true, nil, false) end

Plugin.close()
vim.fn.delete(repo, 'rf')
print('PASS: vv-git 右侧 `-` 目标回归')
