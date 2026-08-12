-- discard 确认的常见生命周期与真实文件副作用回归

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local State = require('vv-git.state')
local Git = require('vv-git.git')
local Loader = require('vv-git.loader')
local Tree = require('vv-git.tree')
local original_confirm = package.loaded['vv-utils.confirm']
local original_discard = Git.discard
local original_discard_untracked = Git.discard_untracked
local original_stage = Git.stage
local original_unstage = Git.unstage
local original_accept_ours = Git.accept_ours
local original_reload = Loader.reload_index
local original_notify = vim.notify

local confirms = {}
local confirm_handles = {}
package.loaded['vv-utils.confirm'] = {
  open = function(opts)
    confirms[#confirms + 1] = opts
    local handle = { closed = false }
    function handle.close() handle.closed = true end
    confirm_handles[#confirm_handles + 1] = handle
    return handle
  end,
}

local discard_callback
local discard_calls = 0
local stage_calls = 0
Git.discard = function(_, paths, callback)
  discard_calls = discard_calls + 1
  assert(paths[1], 'discard 应保留捕获到的相对路径')
  discard_callback = callback
end
Git.discard_untracked = function() error('untracked branch is not part of this test') end
Git.stage = function() stage_calls = stage_calls + 1 end

local reloads = 0
Loader.reload_index = function() reloads = reloads + 1 end

State.clear()
local state = State.create()
state.git_root = '/repo-a'
state.tree = Tree.build({ ['/repo-a/file.txt'] = ' M' }, '/repo-a')
local id = {
  root = '/repo-a',
  base = 'unstaged',
  node = { relpath = 'file.txt', is_dir = false, xy = ' M' },
}
local Actions = require('vv-git.left.actions')

Actions.discard(state, id)
state._closing = true
confirms[1].on_confirm()
assert(discard_calls == 0, '关闭面板应阻止待确认的 discard')
state._closing = nil

Actions.discard(state, id)
State.set_root(state, '/repo-b')
confirms[2].on_confirm()
assert(discard_calls == 0, '切换 root 应阻止待确认的 discard')
local confirms_before_stale_root = #confirms
Actions.discard(state, id)
Actions.toggle_stage(state, id)
assert(#confirms == confirms_before_stale_root, '旧 root 条目不应打开 discard 确认')
assert(stage_calls == 0, '旧 root 条目不能将 toggle_stage 路由到 Git')
State.set_root(state, '/repo-a')

Actions.discard(state, id)
local calls_before_aba = discard_calls
State.set_root(state, '/repo-b')
State.set_root(state, '/repo-a')
confirms[3].on_confirm()
assert(discard_calls == calls_before_aba, 'A 到 B 再到 A 时应拒绝旧的 discard 确认')

Actions.discard(state, id)
Actions.discard(state, id)
assert(confirm_handles[4].closed, '较新的 discard 请求应关闭被替代确认')
local calls_before_stale = discard_calls
confirms[4].on_confirm()
assert(discard_calls == calls_before_stale, '被替代的 discard 确认不能启动 Git')
confirms[5].on_confirm()
assert(discard_calls == calls_before_stale + 1, '最新的 discard 确认应启动 Git')
state._closing = true
discard_callback(false, 'forced discard failure')
discard_callback(true)
assert(reloads == 0, '关闭后完成的 discard 不能重载旧面板')

-- 多选 discard 通过同一个生产入口批量执行，成功后只刷新一次。
state._closing = nil
state.tree = Tree.build({
  ['/repo-a/a.txt'] = ' M',
  ['/repo-a/b.txt'] = ' M',
}, '/repo-a')
Actions.discard_selection(state, {
  { root = '/repo-a', base = 'unstaged', relpath = 'a.txt' },
  { root = '/repo-a', base = 'unstaged', relpath = 'b.txt' },
})
local multi_confirm = confirms[#confirms]
multi_confirm.on_confirm()
assert(discard_calls == calls_before_stale + 2, '多选 discard 应按捕获路径执行')
discard_callback(true)
assert(reloads == 1, '批量 discard 成功后应刷新一次')

-- staged 预处理尚未完成时切换仓库，不能再为旧仓库打开删除确认框。
local unstage_callback
Git.unstage = function(_, _, callback) unstage_callback = callback end
local confirms_before_root_switch = #confirms
Actions.discard_selection(state, {
  { root = '/repo-a', base = 'staged', relpath = 'a.txt' },
  { root = '/repo-a', base = 'unstaged', relpath = 'b.txt' },
})
assert(unstage_callback, '混合 discard 应先执行 staged 预处理')
State.set_root(state, '/repo-b')
unstage_callback(true)
assert(#confirms == confirms_before_root_switch,
  'staged 预处理期间切换 root 后不能为旧仓库打开 discard 确认')
State.set_root(state, '/repo-a')
Git.unstage = original_unstage

-- 已打开确认框后子仓库从 state.subrepos 消失，不能继续触碰旧目标。
local nested_parent = vim.fn.tempname()
local nested_root = nested_parent .. '/nested'
local nested_path = nested_root .. '/removed.txt'
vim.fn.mkdir(nested_root, 'p')
vim.fn.writefile({ 'keep' }, nested_path)
state.subrepos = {
  {
    root = nested_root,
    tree = Tree.build({ [nested_path] = '??' }, nested_root),
    index = {},
  },
}
state.tree = Tree.build({}, '/repo-a')
id = {
  root = nested_root,
  base = 'unstaged',
  node = { relpath = 'removed.txt', is_dir = false, xy = '??' },
}
Git.discard_untracked = original_discard_untracked
Actions.discard(state, id)
state.subrepos = {}
confirms[#confirms].on_confirm()
assert(vim.uv.fs_stat(nested_path),
  '子仓库从 state.subrepos 消失后不能删除旧确认目标')
Git.discard_untracked = function() error('untracked branch is not part of this test') end
vim.fn.delete(nested_parent, 'rf')
state.tree = Tree.build({
  ['/repo-a/a.txt'] = ' M',
  ['/repo-a/b.txt'] = ' M',
}, '/repo-a')

-- 单选 conflict accept 完成时 owner 已过期，不能刷新新上下文。
local accept_callback
Git.accept_ours = function(_, _, callback) accept_callback = callback end
state.tree = Tree.build({ ['/repo-a/conflict.txt'] = 'UU' }, '/repo-a')
id = {
  root = '/repo-a',
  base = 'conflicts',
  node = { relpath = 'conflict.txt', is_dir = false, xy = 'UU' },
}
local reloads_before_stale_accept = reloads
Actions.accept_ours(state, id)
assert(accept_callback, '单选 conflict accept 应保留完成回调')
State.set_root(state, '/repo-b')
accept_callback(true)
assert(reloads == reloads_before_stale_accept,
  'owner 过期后的单选 conflict accept 不能刷新新上下文')
Git.accept_ours = original_accept_ours
State.set_root(state, '/repo-a')

-- Git 已经触碰目标后才失败时，既要报告错误，也要刷新以呈现真实磁盘状态。
local failure_message
vim.notify = function(message) failure_message = tostring(message) end
Actions.discard(state, id)
confirms[#confirms].on_confirm()
discard_callback(false, 'forced partial failure')
assert(failure_message and failure_message:find('forced partial failure', 1, true),
  '部分执行的 discard 应报告失败')
assert(reloads == 2, '部分执行的 discard 应刷新面板状态')
vim.notify = original_notify

state.panel = { id_by_line = { [1] = id } }
State.set_root(state, '/repo-c')
assert(next(state.panel.id_by_line) == nil, '切换 root 后应失效旧的面板行快照')

-- 真实 tracked discard：生产 Git 实现恢复目标文件，不影响邻近文件。
local tracked_root = vim.fn.tempname()
vim.fn.mkdir(tracked_root, 'p')
vim.fn.system({ 'git', '-C', tracked_root, 'init', '-q' })
vim.fn.system({ 'git', '-C', tracked_root, 'config', 'user.email', 'vv-git@example.invalid' })
vim.fn.system({ 'git', '-C', tracked_root, 'config', 'user.name', 'vv-git test' })
local tracked_path = tracked_root .. '/tracked.txt'
local neighbor_path = tracked_root .. '/neighbor.txt'
vim.fn.writefile({ 'original' }, tracked_path)
vim.fn.writefile({ 'neighbor' }, neighbor_path)
vim.fn.system({ 'git', '-C', tracked_root, 'add', 'tracked.txt', 'neighbor.txt' })
vim.fn.system({ 'git', '-C', tracked_root, 'commit', '-qm', 'fixture' })
vim.fn.writefile({ 'modified' }, tracked_path)
Git.discard = original_discard
State.clear()
state = State.create()
state.git_root = tracked_root
state.tree = Tree.build({ [tracked_path] = ' M' }, tracked_root)
id = {
  root = tracked_root,
  base = 'unstaged',
  node = Tree.leaf_at(state.tree.unstaged, 'tracked.txt'),
}
Actions.discard(state, id)
confirms[#confirms].on_confirm()
assert(vim.wait(5000, function()
  return vim.deep_equal(vim.fn.readfile(tracked_path), { 'original' })
end, 10), '确认的 tracked discard 应恢复提交内容')
assert(vim.deep_equal(vim.fn.readfile(neighbor_path), { 'neighbor' }),
  '确认的 tracked discard 应保留相邻文件')
vim.fn.delete(tracked_root, 'rf')

-- 真实 untracked discard：确认后只删除捕获目标，不影响同目录其他文件。
local untracked_root = vim.fn.tempname()
vim.fn.mkdir(untracked_root .. '/nested', 'p')
vim.fn.system({ 'git', '-C', untracked_root, 'init', '-q' })
local delete_path = untracked_root .. '/nested/delete.txt'
local keep_path = untracked_root .. '/nested/keep.txt'
vim.fn.writefile({ 'delete' }, delete_path)
vim.fn.writefile({ 'keep' }, keep_path)
Git.discard_untracked = original_discard_untracked
State.clear()
state = State.create()
state.git_root = untracked_root
state.tree = Tree.build({ [delete_path] = '??', [keep_path] = '??' }, untracked_root)
id = {
  root = untracked_root,
  base = 'unstaged',
  node = Tree.leaf_at(state.tree.unstaged, 'nested/delete.txt'),
}
assert(id.node, '未跟踪样例文件应存在于生产树')
Actions.discard(state, id)
state.tree = Tree.build({ [delete_path] = '??', [keep_path] = '??' }, untracked_root)
state.subrepos = {}
confirms[#confirms].on_confirm()
assert(not vim.uv.fs_stat(delete_path),
  '被动状态重建不应阻塞已确认的 untracked discard')
assert(vim.uv.fs_stat(keep_path), '确认的 untracked discard 应保留相邻文件')

vim.fn.delete(untracked_root, 'rf')

Git.discard = original_discard
Git.discard_untracked = original_discard_untracked
Git.stage = original_stage
Git.unstage = original_unstage
Git.accept_ours = original_accept_ours
Loader.reload_index = original_reload
vim.notify = original_notify
package.loaded['vv-utils.confirm'] = original_confirm
State.clear()
print('PASS: vv-git discard 上下文')
