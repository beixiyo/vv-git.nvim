-- Loader 重载请求所有权与 Git producer 取消回归

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Git = require('vv-git.git')
local Lifecycle = require('vv-git.core.lifecycle')
local Loader = require('vv-git.loader')
local LeftRender = require('vv-git.left.render')
local State = require('vv-git.state')
local UGit = require('vv-utils.git')

local function assert_eq(actual, expected, message)
  assert(actual == expected, message .. ': expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end

local original_index = Git.index
local original_repo_info = Git.repo_info
local original_render = LeftRender.render
local original_ignored_entries = UGit.ignored_entries
local original_exec_autocmds = vim.api.nvim_exec_autocmds
local pending = {}
local cancels = {}
local renders = {}
local events = 0
local on_event
local on_render

Git.index = function(root_name, callback)
  local request = pending[#pending]
  request.index = callback
  return function() cancels[request.name .. ':index'] = (cancels[request.name .. ':index'] or 0) + 1 end
end
Git.repo_info = function(root_name, callback)
  local request = pending[#pending]
  request.info = callback
  return function() cancels[request.name .. ':info'] = (cancels[request.name .. ':info'] or 0) + 1 end
end
LeftRender.render = function(state)
  renders[#renders + 1] = state.branch
  if on_render then on_render() end
end
vim.api.nvim_exec_autocmds = function(event, opts)
  if event == 'User' and opts.pattern == 'VVGitStatusChanged' then
    events = events + 1
    if on_event then on_event() end
  end
end

State.clear()
local state = State.create()
state.git_root = '/repo'
state.selection = {}

pending[#pending + 1] = { name = 'A' }
local after_a = 0
Loader.reload_index(state, function() after_a = after_a + 1 end)
pending[#pending + 1] = { name = 'B' }
local after_b = 0
Loader.reload_index(state, function() after_b = after_b + 1 end)

assert_eq(cancels['A:index'], 1, 'B 物理取消 A 的 index 请求')
assert_eq(cancels['A:info'], 1, 'B 物理取消 A 的 repo_info 请求')
assert_eq(cancels['B:index'], nil, '旧请求清理不取消 B 的 index 请求')
assert_eq(cancels['B:info'], nil, '旧请求清理不取消 B 的 repo_info 请求')

pending[2].info({ branch = 'new' })
pending[2].index({ status_map = {}, rename_map = {} })
pending[1].index({ status_map = {}, rename_map = {} })
pending[1].info({ branch = 'old' })
assert_eq(state.branch, 'new', 'A 的慢回调不能覆盖 B 的快回调')
assert_eq(vim.inspect(renders), vim.inspect({ 'new' }), '仅 B 触发 render')
assert_eq(after_a, 0, 'A 的 after 回调被抑制')
assert_eq(after_b, 1, 'B 的 after 回调仅发布一次')
assert_eq(events, 1, '仅 B 发出状态事件')

pending[#pending + 1] = { name = 'C' }
local after_c = 0
Loader.reload_index(state, function() after_c = after_c + 1 end)
local lifecycle = Lifecycle.new({
  controller = {},
  config = function() return {} end,
  track_panel_width = function() end,
  persist_panel_width = function() end,
})
lifecycle._cancel_reload_requests(state)
assert_eq(cancels['C:index'], 1, 'close 会终止尚未完成的 index')
assert_eq(cancels['C:info'], 1, 'close 会终止尚未完成的 repo_info')
pending[3].index({ status_map = {}, rename_map = {} })
pending[3].info({ branch = 'closed' })
assert_eq(after_c, 0, 'close 前排队的回调不能在关闭后发布')
assert_eq(state.branch, 'new', 'close 后遗留回调不能修改 state')

local ignored_callback
local ignored_cancels = 0
UGit.ignored_entries = function(_, callback)
  ignored_callback = callback
  return function() ignored_cancels = ignored_cancels + 1 end
end
state._subrepo = {
  depth = function() return 1 end,
  config = function() return { respect_gitignore = true } end,
}
Loader.reload_index(state)
Loader.cancel_reload(state)
assert_eq(ignored_cancels, 1, 'respect_gitignore producer 属于对应的 reload 请求')
ignored_callback({}, {})
assert_eq(#pending, 3, 'cancel 后的 ignored 回调不能启动 repository producers')

state._subrepo = nil
state.git_root = '/repo-before-root-change'
pending[#pending + 1] = { name = 'D' }
local after_d = 0
Loader.reload_index(state, function() after_d = after_d + 1 end)
State.set_root(state, '/repo-after-root-change')
pending[4].index({ status_map = {}, rename_map = {} })
pending[4].info({ branch = 'wrong-root' })
assert_eq(cancels['D:index'], 1, 'root 漂移时 callback 会终止自己的 index producer')
assert_eq(cancels['D:info'], 1, 'root 漂移时 callback 会终止剩余 repo_info producer')
assert_eq(after_d, 0, '捕获的 root 漂移在 successor 启动前使旧请求失效')
assert_eq(state.branch, 'new', '仅 root 漂移已足以阻止过期状态写入')
assert_eq(vim.inspect(renders), vim.inspect({ 'new' }), 'root 漂移后的请求不会 render')

state.git_root = '/repo-reentry'
pending[#pending + 1] = { name = 'E' }
local after_e, after_f = 0, 0
Loader.reload_index(state, function() after_e = after_e + 1 end)
on_event = function()
  on_event = nil
  pending[#pending + 1] = { name = 'F' }
  Loader.reload_index(state, function() after_f = after_f + 1 end)
end
pending[5].index({ status_map = {}, rename_map = {} })
pending[5].info({ branch = 'event-old' })
assert_eq(after_e, 0, '发布期间启动的 successor 停止旧的 after 回调')
pending[6].index({ status_map = {}, rename_map = {} })
pending[6].info({ branch = 'event-new' })
assert_eq(after_f, 1, 'publication 中启动的 successor 可完成')
assert_eq(state.branch, 'event-new', 'publication 的 successor 拥有最终状态')

state.git_root = '/repo-render-reentry'
pending[#pending + 1] = { name = 'G' }
local after_g, after_h = 0, 0
Loader.reload_index(state, function() after_g = after_g + 1 end)
on_render = function()
  on_render = nil
  pending[#pending + 1] = { name = 'H' }
  Loader.reload_index(state, function() after_h = after_h + 1 end)
end
pending[7].index({ status_map = {}, rename_map = {} })
pending[7].info({ branch = 'render-old' })
assert_eq(after_g, 0, '由 render 启动的 successor 停止旧事件和 after 回调')
pending[8].index({ status_map = {}, rename_map = {} })
pending[8].info({ branch = 'render-new' })
assert_eq(after_h, 1, 'render 期间启动的 successor 可完成')
assert_eq(state.branch, 'render-new', 'render 的 successor 拥有最终状态')

state.git_root = '/repo-after-error'
pending[#pending + 1] = { name = 'I' }
Loader.reload_index(state, function() error('injected after failure') end)
pending[9].index({ status_map = {}, rename_map = {} })
local publish_ok, publish_err = pcall(pending[9].info, { branch = 'after-error' })
assert(not publish_ok and tostring(publish_err):find('injected after failure', 1, true),
  'publication 错误必须可见')
pending[#pending + 1] = { name = 'J' }
Loader.reload_index(state)
assert_eq(cancels['I:index'], nil, '失败 publication 应彻底释放已完成的 index')
assert_eq(cancels['I:info'], nil, '失败 publication 应彻底释放已完成的 repo_info')
Loader.cancel_reload(state)

Git.index = original_index
Git.repo_info = original_repo_info
LeftRender.render = original_render
UGit.ignored_entries = original_ignored_entries
vim.api.nvim_exec_autocmds = original_exec_autocmds
State.clear()

-- repo_info 的取消只终止仍处于 active 的 producer
local original_system = vim.system
local original_schedule = vim.schedule
local handles = {}
vim.system = function(command)
  local handle = { command = command, kills = 0 }
  function handle:kill(signal)
    assert_eq(signal, 'sigterm', 'repo_info 取消时使用 sigterm')
    self.kills = self.kills + 1
  end
  handles[#handles + 1] = handle
  return handle
end

local delivered = 0
local cancel_repo_info = Git.repo_info('/repo', function() delivered = delivered + 1 end)
cancel_repo_info()
cancel_repo_info()
assert_eq(#handles, 2, 'repo_info 会启动两个生产级 Git 命令')
assert_eq(handles[1].kills, 1, '取消 repo_info 时会终止 status 进程一次')
assert_eq(handles[2].kills, 1, '取消 repo_info 时会终止 remote 进程一次')
assert_eq(delivered, 0, '生产者取消后不会发布')

-- 原始进程完成后会在 Lua delivery 执行前释放物理所有权
local queued = {}
handles = {}
vim.schedule = function(callback) queued[#queued + 1] = callback end
vim.system = function(command, _, callback)
  local handle = { command = command, kills = 0 }
  function handle:kill() self.kills = self.kills + 1 end
  handles[#handles + 1] = handle
  callback({ code = 0, stdout = command[#command] == 'remote' and 'origin\n' or '# branch.oid abcdef\n# branch.head main\n' })
  return handle
end

delivered = 0
cancel_repo_info = Git.repo_info('/repo', function() delivered = delivered + 1 end)
cancel_repo_info()
for _, callback in ipairs(queued) do callback() end
assert_eq(handles[1].kills, 0, 'delivery 排队时已完成的 status 生产者不会被 kill')
assert_eq(handles[2].kills, 0, 'delivery 排队时已完成的 remote 生产者不会被 kill')
assert_eq(delivered, 0, '原始执行完成后 cancel 会抑制排队 callback')

-- 后续 producer 构造失败会回滚先前的 active producer，并通过回调报告
queued = {}
handles = {}
local spawn_count = 0
vim.system = function(command)
  spawn_count = spawn_count + 1
  if spawn_count == 2 then error('injected second spawn failure') end
  local handle = { command = command, kills = 0 }
  function handle:kill() self.kills = self.kills + 1 end
  handles[#handles + 1] = handle
  return handle
end

local spawn_error
local repo_ok, repo_cancel = pcall(Git.repo_info, '/repo', function(info, err)
  assert_eq(info, nil, '生产者构造失败不能发布 repository info')
  spawn_error = err
end)
assert(repo_ok and type(repo_cancel) == 'function', 'repo_info 在生产者构造失败时也应返回取消函数')
assert_eq(handles[1].kills, 1, '第二次 spawn 失败会回滚第一个活跃生产者')
for _, callback in ipairs(queued) do callback() end
assert(spawn_error and spawn_error:find('injected second spawn failure', 1, true),
  'repo_info 只报告一次构造失败')

-- 网络 helper 向命令 request scope 暴露只取消 active producer 的精确能力
queued = {}
handles = {}
vim.system = function(command, _, callback)
  local handle = { command = command, callback = callback, kills = 0 }
  function handle:kill() self.kills = self.kills + 1 end
  handles[#handles + 1] = handle
  return handle
end
local network_deliveries = 0
local cancel_push = Git.push('/repo', function() network_deliveries = network_deliveries + 1 end)
cancel_push()
assert_eq(handles[1].kills, 1, 'active push 生产者被物理终止')
handles[1].callback({ code = 0, stdout = '' })
for _, callback in ipairs(queued) do callback() end
assert_eq(network_deliveries, 0, '被 cancel 的 push 不会发布排队结果')

queued = {}
local cancel_publish = Git.publish('/repo', 'origin', function() network_deliveries = network_deliveries + 1 end)
handles[2].callback({ code = 0, stdout = '' })
cancel_publish()
for _, callback in ipairs(queued) do callback() end
assert_eq(handles[2].kills, 0, 'publish 已完成时在 Lua 回调前不会被 kill')
assert_eq(network_deliveries, 0, 'publish cancel 仍会抑制排队回调')

queued = {}
vim.system = function() error('injected push spawn failure') end
local push_error
local push_ok, failed_push_cancel = pcall(Git.push, '/repo', function(ok, out)
  assert_eq(ok, false, 'push 构造失败不能返回成功')
  push_error = out
end)
assert(push_ok and type(failed_push_cancel) == 'function',
  '单次网络生产者的 spawn 错误不应透传 async API')
failed_push_cancel()
for _, callback in ipairs(queued) do callback() end
assert_eq(push_error, nil, 'cancel 会抑制排队的网络构造错误')

queued = {}
Git.push('/repo', function(ok, out)
  assert_eq(ok, false, 'push 构造失败不能返回成功')
  push_error = out
end)
for _, callback in ipairs(queued) do callback() end
assert(push_error and push_error:find('injected push spawn failure', 1, true),
  'push 构造失败通过普通回调返回')

vim.system = original_system
vim.schedule = original_schedule

print('PASS: vv-git loader latest 请求优先与物理取消')
