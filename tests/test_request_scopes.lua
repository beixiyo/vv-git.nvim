-- vv-git 生命周期与自动刷新 request-scope 回归

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Autocmds = require('vv-git.autocmds')
local Commands = require('vv-git.core.commands')
local Git = require('vv-git.git')
local Lifecycle = require('vv-git.core.lifecycle')
local Loader = require('vv-git.loader')
local RightView = require('vv-git.right.view')
local State = require('vv-git.state')
local UGit = require('vv-utils.git')
local Timer = require('vv-utils.timer')

local function assert_eq(actual, expected, message)
  assert(actual == expected, message .. ': expected ' .. vim.inspect(expected) .. ', got ' .. vim.inspect(actual))
end

local function count_timers()
  local count = 0
  vim.uv.walk(function(handle)
    if handle:get_type() == 'timer' and not handle:is_closing() then count = count + 1 end
  end)
  return count
end

local noop = function() end
local handlers = {
  on_refresh = noop,
  on_apply_layout = noop,
  on_ensure_invariant = noop,
  on_reshow_view = noop,
  on_closed = noop,
  on_external_root = noop,
}

-- 重复 setup 只持有一个存活的 debounce timer，停用时会释放
local timers_before = count_timers()
Autocmds.setup(handlers, { auto_refresh = true })
local timers_after_first = count_timers()
Autocmds.setup(handlers, { auto_refresh = true })
local timers_after_second = count_timers()
assert_eq(timers_after_first, timers_before + 1, '首次 setup 会创建一个 debounce 计时器')
assert_eq(timers_after_second, timers_after_first, '第二次 setup 会释放上一个 debounce 计时器')
Autocmds.setup(handlers, { auto_refresh = false })
vim.wait(20)
assert_eq(count_timers(), timers_before, '关闭 auto refresh 时会释放 setup 持有的计时器')

-- scheduled refresh 与 external-root 回归共用当前 panel state
State.clear()
local state = State.create()
state.git_root = '/repo-old'
state.panel = { buf = 1, win = 1 }

-- 非 debounce 的 scheduled refresh 由 setup generation 和 ticket identity 共同持有
local original_schedule = vim.schedule
local scheduled_refreshes = {}
local old_setup_refreshes = 0
local new_setup_refreshes = 0
local new_setup_reshows = 0
vim.schedule = function(callback) scheduled_refreshes[#scheduled_refreshes + 1] = callback end
local old_scheduled_handlers = vim.tbl_extend('force', handlers, {
  on_refresh = function() old_setup_refreshes = old_setup_refreshes + 1 end,
})
local new_scheduled_handlers = vim.tbl_extend('force', handlers, {
  on_refresh = function() new_setup_refreshes = new_setup_refreshes + 1 end,
  on_reshow_view = function() new_setup_reshows = new_setup_reshows + 1 end,
})
local saved_name = vim.api.nvim_buf_get_name(0)
vim.api.nvim_buf_set_name(0, '/repo-old/scheduled.lua')
Autocmds.setup(old_scheduled_handlers, { auto_refresh = false })
vim.api.nvim_exec_autocmds('BufWritePost', { buffer = 0 })
Autocmds.setup(new_scheduled_handlers, { auto_refresh = false })
vim.api.nvim_exec_autocmds('User', { pattern = 'GitSignsChanged' })
assert_eq(#scheduled_refreshes, 2, '新旧 setup 各自入队一次生产刷新')
scheduled_refreshes[1]()
scheduled_refreshes[2]()
vim.schedule = original_schedule
if saved_name ~= '' then vim.api.nvim_buf_set_name(0, saved_name) end
assert_eq(old_setup_refreshes, 0, '旧 setup 的 scheduled 回调不会触发刷新')
assert_eq(new_setup_refreshes, 1, '新 setup 的刷新不会被旧 pending 票据吞掉')
assert_eq(new_setup_reshows, 1, '新 GitSignsChanged 票据保留重显意图')

-- refresh handler 可同步替换 setup；旧调用栈不得 reshow 新 owner
local reentrant_schedules = {}
local reentrant_old_refreshes = 0
local reentrant_old_reshows = 0
local reentrant_new_refreshes = 0
local reentrant_new_reshows = 0
vim.schedule = function(callback) reentrant_schedules[#reentrant_schedules + 1] = callback end
local reentrant_new_handlers = vim.tbl_extend('force', handlers, {
  on_refresh = function() reentrant_new_refreshes = reentrant_new_refreshes + 1 end,
  on_reshow_view = function() reentrant_new_reshows = reentrant_new_reshows + 1 end,
})
local reentrant_old_handlers = vim.tbl_extend('force', handlers, {
  on_refresh = function()
    reentrant_old_refreshes = reentrant_old_refreshes + 1
    Autocmds.setup(reentrant_new_handlers, { auto_refresh = false })
    vim.api.nvim_exec_autocmds('User', { pattern = 'GitSignsChanged' })
  end,
  on_reshow_view = function() reentrant_old_reshows = reentrant_old_reshows + 1 end,
})
Autocmds.setup(reentrant_old_handlers, { auto_refresh = false })
vim.api.nvim_exec_autocmds('User', { pattern = 'GitSignsChanged' })
assert_eq(#reentrant_schedules, 1, '旧 setup 会排入一次生产刷新')
reentrant_schedules[1]()
assert_eq(reentrant_old_refreshes, 1, '旧刷新处理器先执行旧 refresh')
assert_eq(reentrant_old_reshows, 0, '旧调用栈替换 setup 后不能再重显')
assert_eq(#reentrant_schedules, 2, '替换后的 setup 排入自己的刷新')
reentrant_schedules[2]()
vim.schedule = original_schedule
assert_eq(reentrant_new_refreshes, 1, '替换后的 setup 的刷新依然执行')
assert_eq(reentrant_new_reshows, 1, '替换后的 setup 保留重显权限')

-- 同 owner 的低优先级 successor 会继承已经要求的 reshow
local successor_schedules = {}
local successor_refreshes = 0
local successor_reshows = 0
vim.schedule = function(callback) successor_schedules[#successor_schedules + 1] = callback end
local successor_handlers = vim.tbl_extend('force', handlers, {
  on_refresh = function()
    successor_refreshes = successor_refreshes + 1
    if successor_refreshes == 1 then
      vim.api.nvim_exec_autocmds('BufWritePost', { buffer = 0 })
    end
  end,
  on_reshow_view = function() successor_reshows = successor_reshows + 1 end,
})
Autocmds.setup(successor_handlers, { auto_refresh = false })
vim.api.nvim_exec_autocmds('User', { pattern = 'GitSignsChanged' })
successor_schedules[1]()
assert_eq(successor_reshows, 0, '同 owner 的旧票据会把重显延后给后继者')
assert_eq(#successor_schedules, 2, '刷新处理器排入低优先级后继者')
successor_schedules[2]()
vim.schedule = original_schedule
assert_eq(successor_refreshes, 2, '同 owner 的后继者执行后续刷新')
assert_eq(successor_reshows, 1, '同 owner 的后继者继承原始重显意图')

-- 已由 libuv 排队的 debounce callback 不能越过 setup owner 生命周期
local original_debounce = Timer.debounce
local queued_refresh
local stale_refreshes = 0
Timer.debounce = function(callback)
  return function(...)
    local args = { ... }
    queued_refresh = function() callback(unpack(args)) end
  end, noop
end
local queued_handlers = vim.tbl_extend('force', handlers, {
  on_refresh = function() stale_refreshes = stale_refreshes + 1 end,
})
Autocmds.setup(queued_handlers, { auto_refresh = true })
vim.api.nvim_exec_autocmds('FocusGained', {})
assert(type(queued_refresh) == 'function', '生产 autocmd 会排队 debounce 刷新')
Autocmds.setup(queued_handlers, { auto_refresh = false })
queued_refresh()
assert_eq(stale_refreshes, 0, 'setup 失效后，入队的 debounce 回调不能刷新')
Timer.debounce = original_debounce

local original_root_async = UGit.root_async
local original_reload = Loader.reload_index
local original_right_close = RightView.close
local pending_roots = {}
local cancelled_roots = {}
local reloads = {}
UGit.root_async = function(path, callback)
  pending_roots[path] = callback
  return function() cancelled_roots[path] = (cancelled_roots[path] or 0) + 1 end
end
Loader.reload_index = function(current) reloads[#reloads + 1] = current.git_root end
RightView.close = noop

local controller = {
  _cancel_command_requests = noop,
  _context = function() return {} end,
  _emit_closed = noop,
  _invoke_callback = noop,
  _apply_layout = noop,
}
local lifecycle = Lifecycle.new({
  controller = controller,
  config = function() return {} end,
  track_panel_width = noop,
  persist_panel_width = noop,
})
lifecycle._follow_external_root('/repo-a')
lifecycle._follow_external_root('/repo-b')
assert_eq(cancelled_roots['/repo-a'], 1, '新 external root 会物理取消旧 lookup')
pending_roots['/repo-b']('/repo-b')
pending_roots['/repo-a']('/repo-a')
assert_eq(state.git_root, '/repo-b', '以新 external root 为准')
assert_eq(vim.inspect(reloads), vim.inspect({ '/repo-b' }), '仅最新 root 会执行 reload')

UGit.root_async = original_root_async
Loader.reload_index = original_reload
RightView.close = original_right_close

-- 关闭 UI 只使 command callback 失效，不物理终止仍可独立完成的 push producer
local original_push = Git.push
local push_callback
local push_cancels = 0
local push_notifications = 0
local push_refreshes = 0
local original_notify = vim.notify
Git.push = function(_, callback)
  push_callback = callback
  return function() push_cancels = push_cancels + 1 end
end
vim.notify = function() push_notifications = push_notifications + 1 end

local close_commands = Commands.new({
  controller = {
    refresh = function() push_refreshes = push_refreshes + 1 end,
    _invoke_callback = noop,
    _context = function() return {} end,
  },
  config = function() return { binary = {} } end,
})
local close_invalidations = 0
local close_controller = {
  _invalidate_command_requests = function()
    close_invalidations = close_invalidations + 1
    close_commands._invalidate_command_requests()
  end,
  _context = function() return {} end,
  _emit_closed = noop,
  _invoke_callback = noop,
  _apply_layout = noop,
}
local close_lifecycle = Lifecycle.new({
  controller = close_controller,
  config = function() return {} end,
  track_panel_width = noop,
  persist_panel_width = noop,
})
state.git_root = '/repo-close'
state.tabpage = nil
close_commands._push()
assert_eq(push_notifications, 1, 'Lifecycle close 前 push 已开始')
assert(close_lifecycle.close(), 'Lifecycle.close 处理无活跃 tab 的 owner')
assert_eq(close_invalidations, 1, 'Lifecycle.close 会使命令请求失效')
assert_eq(push_cancels, 0, 'Lifecycle.close 不会取消活跃 push 生产者')
push_callback(true, 'done')
assert_eq(push_notifications, 2, 'Lifecycle.close 后已启动的 push 完成仍应发布')
assert_eq(push_refreshes, 0, 'Lifecycle.close 后 push 完成不能刷新已关闭 UI')

Git.push = original_push
vim.notify = original_notify
State.clear()
print('PASS: vv-git request scopes 生命周期')
