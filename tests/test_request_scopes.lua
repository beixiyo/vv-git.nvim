-- vv-git 生命周期与 UI 所有权的 request-scope 回归

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local Autocmds = require('vv-git.autocmds')
local Commands = require('vv-git.core.commands')
local FileCompare = require('vv-git.file_compare')
local FileCompareWinopts = require('vv-git.file_compare.winopts')
local Git = require('vv-git.git')
local Guard = require('vv-git.guard')
local Keymaps = require('vv-git.core.keymaps')
local Lifecycle = require('vv-git.core.lifecycle')
local Loader = require('vv-git.loader')
local Prompt = require('vv-git.left.prompt')
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
assert_eq(timers_after_first, timers_before + 1, 'first setup creates one debounce timer')
assert_eq(timers_after_second, timers_after_first, 'second setup disposes the previous debounce timer')
Autocmds.setup(handlers, { auto_refresh = false })
vim.wait(20)
assert_eq(count_timers(), timers_before, 'disabling auto refresh releases the setup-owned timer')

-- 较慢的 external-root 查询不能在 B 完成后把面板切回旧 root
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
assert_eq(#scheduled_refreshes, 2, 'old and new setup each queued one production refresh')
scheduled_refreshes[1]()
scheduled_refreshes[2]()
vim.schedule = original_schedule
if saved_name ~= '' then vim.api.nvim_buf_set_name(0, saved_name) end
assert_eq(old_setup_refreshes, 0, 'old setup scheduled callback cannot refresh')
assert_eq(new_setup_refreshes, 1, 'new setup refresh is not swallowed by the old pending ticket')
assert_eq(new_setup_reshows, 1, 'new GitSignsChanged ticket retains its reshow intent')

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
assert_eq(#reentrant_schedules, 1, 'old setup queues its production refresh')
reentrant_schedules[1]()
assert_eq(reentrant_old_refreshes, 1, 'old refresh handler executes before replacing setup')
assert_eq(reentrant_old_reshows, 0, 'old stack cannot reshow after its handler replaces setup')
assert_eq(#reentrant_schedules, 2, 'replacement setup queues its own refresh')
reentrant_schedules[2]()
vim.schedule = original_schedule
assert_eq(reentrant_new_refreshes, 1, 'replacement setup refresh still executes')
assert_eq(reentrant_new_reshows, 1, 'replacement setup owns its reshow')

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
assert_eq(successor_reshows, 0, 'old ticket defers reshow to its same-owner successor')
assert_eq(#successor_schedules, 2, 'refresh handler queues the lower-priority successor')
successor_schedules[2]()
vim.schedule = original_schedule
assert_eq(successor_refreshes, 2, 'same-owner successor performs the follow-up refresh')
assert_eq(successor_reshows, 1, 'same-owner successor inherits the original reshow intent')

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
assert(type(queued_refresh) == 'function', 'production autocmd queues the debounced refresh')
Autocmds.setup(queued_handlers, { auto_refresh = false })
queued_refresh()
assert_eq(stale_refreshes, 0, 'queued debounce callback cannot refresh after setup invalidation')
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
assert_eq(cancelled_roots['/repo-a'], 1, 'new external root physically cancels the old lookup')
pending_roots['/repo-b']('/repo-b')
pending_roots['/repo-a']('/repo-a')
assert_eq(state.git_root, '/repo-b', 'latest external root wins')
assert_eq(vim.inspect(reloads), vim.inspect({ '/repo-b' }), 'only the latest root reloads')

UGit.root_async = original_root_async
Loader.reload_index = original_reload
RightView.close = original_right_close

-- 捕获的 panel root 不再受当前 owner 持有时，commit 和 publish 链必须停止
local original_cursor = Keymaps.id_under_cursor
local original_has_staged = Git.has_staged
local original_repo_info = Git.repo_info
local original_add_remote = Git.add_remote
local original_publish = Git.publish
local original_prompt_open = Prompt.open
local original_prompt_close = Prompt.close
local original_input = vim.ui.input

Keymaps.id_under_cursor = function() return nil end
local staged_callback
local prompt_opens = 0
Git.has_staged = function(_, callback) staged_callback = callback end
Prompt.open = function() prompt_opens = prompt_opens + 1 end
Prompt.close = noop

local command_controller = {
  refresh = noop,
  _invoke_callback = noop,
  _context = function() return {} end,
}
local commands = Commands.new({ controller = command_controller, config = function() return { binary = {} } end })
state.git_root = '/repo-a'
commands._commit()
state.git_root = '/repo-b'
staged_callback(true)
assert_eq(prompt_opens, 0, 'late staged check cannot open a commit prompt for the old root')
commands._cancel_command_requests()

local repo_info_callback
local input_callback
local add_remote_callback
local publishes = 0
local repo_info_cancels = 0
local add_remote_cancels = 0
local publish_cancels = 0
Git.repo_info = function(_, callback)
  repo_info_callback = callback
  return function() repo_info_cancels = repo_info_cancels + 1 end
end
vim.ui.input = function(_, callback) input_callback = callback end
Git.add_remote = function(_, _, _, callback)
  add_remote_callback = callback
  return function() add_remote_cancels = add_remote_cancels + 1 end
end
Git.publish = function()
  publishes = publishes + 1
  return function() publish_cancels = publish_cancels + 1 end
end

state.git_root = '/repo-a'
commands._publish()
commands._cancel_command_requests()
assert_eq(repo_info_cancels, 1, 'publish lifecycle cancellation reaches repo_info producers')

state.git_root = '/repo-a'
commands._publish()
repo_info_callback({
  branch_name = 'main',
  detached = false,
  unborn = false,
  head = 'abc',
  upstream = nil,
  remotes = {},
})
input_callback('git@example/repo.git')
state.git_root = '/repo-b'
add_remote_callback(true)
assert_eq(publishes, 0, 'root change between add-remote and publish stops the old chain')
commands._cancel_command_requests()
assert_eq(add_remote_cancels, 1, 'publish lifecycle cancellation reaches add-remote producer')

state.git_root = '/repo-a'
commands._publish()
repo_info_callback({
  branch_name = 'main',
  detached = false,
  unborn = false,
  head = 'abc',
  upstream = nil,
  remotes = { 'origin' },
})
assert_eq(publishes, 1, 'publish producer starts after repository inspection')
commands._cancel_command_requests()
assert_eq(publish_cancels, 1, 'publish lifecycle cancellation reaches active push producer')

Keymaps.id_under_cursor = original_cursor
Git.has_staged = original_has_staged
Git.repo_info = original_repo_info
Git.add_remote = original_add_remote
Git.publish = original_publish
Prompt.open = original_prompt_open
Prompt.close = original_prompt_close
vim.ui.input = original_input

-- Prompt 持有 stage-all → commit 边界，失效后不得再启动 commit
local original_stage_all = Git.stage_all
local original_commit = Git.commit
local stage_all_callback
local commit_callback
local commit_calls = 0
local prompt_current = true
Git.stage_all = function(_, callback) stage_all_callback = callback end
Git.commit = function(_, _, callback)
  commit_calls = commit_calls + 1
  commit_callback = callback
end

Prompt.open({
  git_root = '/repo-a',
  has_staged = false,
  is_current = function() return prompt_current end,
})
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'test commit' })
local submit_mapping = vim.fn.maparg('<C-s>', 'i', false, true)
assert(type(submit_mapping.callback) == 'function', 'production prompt installs the submit callback')
submit_mapping.callback()
assert(type(stage_all_callback) == 'function', 'commit-all starts stage_all while the owner is current')
prompt_current = false
stage_all_callback(true)
assert_eq(commit_calls, 0, 'invalidated prompt cannot continue from stage_all into commit')
Prompt.close()

local successes = 0
prompt_current = true
Prompt.open({
  git_root = '/repo-a',
  has_staged = true,
  is_current = function() return prompt_current end,
  on_success = function() successes = successes + 1 end,
})
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'test commit' })
vim.fn.maparg('<C-s>', 'i', false, true).callback()
assert_eq(commit_calls, 1, 'current prompt starts commit')
prompt_current = false
commit_callback(true)
assert_eq(successes, 0, 'invalidated commit callback cannot publish success side effects')
Prompt.close()

Git.stage_all = original_stage_all
Git.commit = original_commit

-- Prompt 挂载可同步启动 B；A 的晚到 disposer 必须仍只处理自身 owner
vim.cmd('stopinsert')
vim.cmd('only')
local prompt_a_current = true
local dispose_prompt_b
local prompt_reentry_group = vim.api.nvim_create_augroup('VVGitPromptReentryTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = prompt_reentry_group,
  once = true,
  callback = function()
    prompt_a_current = false
    dispose_prompt_b = Prompt.open({
      git_root = '/repo-b',
      has_staged = true,
      is_current = function() return true end,
    })
  end,
})
local dispose_prompt_a = Prompt.open({
  git_root = '/repo-a',
  has_staged = true,
  is_current = function() return prompt_a_current end,
})
local prompt_b_win = vim.api.nvim_get_current_win()
local prompt_b_buf = vim.api.nvim_get_current_buf()
dispose_prompt_a()
assert(vim.api.nvim_win_is_valid(prompt_b_win) and vim.api.nvim_buf_is_valid(prompt_b_buf),
  'stale prompt disposer closed the reentrant replacement prompt')
dispose_prompt_b()

-- root 或生命周期失效后，push/pull 回调不得发布结果
local original_push = Git.push
local original_notify = vim.notify
local push_callback
local push_cancels = 0
local net_notifications = 0
local net_refreshes = 0
Git.push = function(_, callback)
  push_callback = callback
  return function() push_cancels = push_cancels + 1 end
end
vim.notify = function() net_notifications = net_notifications + 1 end
local net_commands = Commands.new({
  controller = {
    refresh = function() net_refreshes = net_refreshes + 1 end,
    _invoke_callback = noop,
    _context = function() return {} end,
  },
  config = function() return { binary = {} } end,
})
state.git_root = '/repo-a'
net_commands._push()
assert_eq(net_notifications, 1, 'push start notification is emitted while current')
state.git_root = '/repo-b'
push_callback(true, 'done')
assert_eq(net_notifications, 1, 'stale push callback emits no completion notification')
assert_eq(net_refreshes, 0, 'stale push callback cannot refresh the new root')

state.git_root = '/repo-a'
net_commands._push()
net_commands._cancel_command_requests()
assert_eq(push_cancels, 1, 'push lifecycle cancellation reaches its active producer')
push_callback(true, 'done')
assert_eq(net_notifications, 2, 'cancelled push callback emits no completion notification')
assert_eq(net_refreshes, 0, 'cancelled push callback cannot refresh')
Git.push = original_push
vim.notify = original_notify

-- File compare 遵循 latest-wins，并保留 source 窗口与 tab 快照
local original_show = Git.show
local original_root = UGit.root
local pending_shows = {}
Git.show = function(_, ref, _, callback) pending_shows[ref] = callback end

vim.cmd('only')
local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(source_buf, '/repo/file.lua')
vim.bo[source_buf].filetype = 'lua'
vim.api.nvim_win_set_buf(0, source_buf)
UGit.root = function() return '/repo' end

assert(FileCompare.open('A', { bufnr = source_buf, root = '/repo' }))
assert(FileCompare.open('B', { bufnr = source_buf, root = '/repo' }))
pending_shows.B({ 'new' })
pending_shows.A({ 'old' })

local ref_windows = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  if name:match('^vv%-git://file/') then ref_windows[#ref_windows + 1] = win end
end
assert_eq(#ref_windows, 1, 'late compare A cannot mount a second stale UI')

assert(FileCompare.open('C', { bufnr = source_buf, root = '/repo' }))
local pending_owner_win = vim.api.nvim_get_current_win()
vim.cmd('new')
vim.api.nvim_set_current_win(pending_owner_win)
pending_shows.C({ 'stale-window' })
ref_windows = {}
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  if name:match('^vv%-git://file/') then ref_windows[#ref_windows + 1] = win end
end
assert_eq(#ref_windows, 0, 'leaving and returning to the pending owner window cannot revive compare UI')

-- A 的 WinEnter 同步启动 B 后，UI 归 B 所有；旧 A 清理不得删除它
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local reentrant_ready
Git.show = function(_, ref, _, callback)
  if ref == 'B-reentrant' then
    callback({ 'B' })
  else
    pending_shows[ref] = callback
  end
end
local reentrant_group = vim.api.nvim_create_augroup('VVGitFileCompareReentrantTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = reentrant_group,
  once = true,
  callback = function()
    FileCompare.open('B-reentrant', {
      bufnr = source_buf,
      root = '/repo',
      on_ready = function(context) reentrant_ready = context end,
    })
  end,
})
assert(FileCompare.open('A-reentrant', { bufnr = source_buf, root = '/repo' }))
pending_shows['A-reentrant']({ 'A' })
vim.wait(50, function() return reentrant_ready ~= nil end)
assert(reentrant_ready and vim.api.nvim_win_is_valid(reentrant_ready.ref_win), 'reentrant B remains mounted')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 2,
  'serialized reentrant mount leaves only the source and latest ref windows')
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(reentrant_ready.ref_win)):match('B%-reentrant'),
  'stale A cleanup does not replace or delete B ref UI')
local reentrant_mapping
vim.api.nvim_buf_call(source_buf, function()
  reentrant_mapping = vim.fn.maparg('q', 'n', false, true)
end)
assert(type(reentrant_mapping.callback) == 'function', 'stale A cleanup does not restore over B mappings')
assert(vim.wo[reentrant_ready.source_win].diff, 'stale A cleanup does not restore over B window options')

-- 替换已经 ready 的 source buffer 会释放 ref 窗口和 listener
local replacement = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(reentrant_ready.source_win, replacement)
vim.wait(50, function() return not vim.api.nvim_win_is_valid(reentrant_ready.ref_win) end)
assert(not vim.api.nvim_win_is_valid(reentrant_ready.ref_win), 'source window buffer change closes ready compare UI')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 1,
  'closing the reentrant compare restores the original one-window layout')

-- source 窗口的 buffer 变化不可逆，即使 schedule 执行前又从 X 切回 source
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
vim.cmd('vsplit')
vim.api.nvim_win_set_buf(0, source_buf)
local aba_ready
Git.show = function(_, _, _, callback) callback({ 'old' }) end
assert(FileCompare.open('HEAD', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) aba_ready = context end,
}))
vim.wait(50, function() return aba_ready ~= nil end)
local aba_replacement = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(aba_ready.source_win, aba_replacement)
vim.api.nvim_win_set_buf(aba_ready.source_win, source_buf)
vim.wait(50, function()
  return not vim.api.nvim_win_is_valid(aba_ready.ref_win)
      and vim.w[aba_ready.source_win].vv_git_file_compare_owner == nil
end)
assert(not vim.api.nvim_win_is_valid(aba_ready.ref_win),
  'same-tick source buffer ABA still closes the old compare owner')
assert(not vim.wo[aba_ready.source_win].diff,
  'returning the source buffer cannot revive ownerless diff state')
assert(vim.wo[aba_ready.source_win].wrap,
  'returning the source buffer restores its pre-compare window options')

-- cleanup 不得借用已经由第三方 wipe buffer 持有的窗口
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local second_source_win = vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local delayed_source_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(second_source_win, source_buf)
vim.api.nvim_win_set_buf(delayed_source_win, source_buf)
vim.api.nvim_set_option_value('wrap', true, { win = delayed_source_win })
vim.api.nvim_set_option_value('foldcolumn', '0', { win = delayed_source_win })
local restore_listeners_before = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local delayed_ready
assert(FileCompare.open('delayed-source-restore', {
  bufnr = source_buf,
  winid = delayed_source_win,
  root = '/repo',
  on_ready = function(context) delayed_ready = context end,
}))
vim.wait(50, function() return delayed_ready ~= nil end)

local wipe_buffer = vim.api.nvim_create_buf(false, true)
vim.bo[wipe_buffer].bufhidden = 'wipe'
vim.api.nvim_buf_set_lines(wipe_buffer, 0, -1, false, { 'caller-owned unsaved content' })
local wipe_events = 0
local wipe_group = vim.api.nvim_create_augroup('VVGitFileCompareWipeOwnerTest', { clear = true })
vim.api.nvim_create_autocmd({ 'BufEnter', 'BufLeave' }, {
  group = wipe_group,
  buffer = wipe_buffer,
  callback = function() wipe_events = wipe_events + 1 end,
})
vim.api.nvim_win_set_buf(delayed_source_win, wipe_buffer)
local events_after_caller_switch = wipe_events
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(delayed_ready.ref_win)
      and vim.w[delayed_source_win].vv_git_file_compare_owner == nil
end)
assert(vim.api.nvim_buf_is_valid(wipe_buffer),
  'cleanup preserves a caller-owned bufhidden=wipe buffer')
assert_eq(vim.api.nvim_win_get_buf(delayed_source_win), wipe_buffer,
  'cleanup never replaces the new window owner')
assert_eq(vim.api.nvim_buf_get_lines(wipe_buffer, 0, -1, false)[1],
  'caller-owned unsaved content', 'cleanup preserves caller-owned scratch content')
assert_eq(wipe_events, events_after_caller_switch,
  'deferred cleanup does not invisibly leave and re-enter the caller buffer')

vim.bo[wipe_buffer].bufhidden = 'hide'
vim.api.nvim_win_set_buf(delayed_source_win, source_buf)
assert(not vim.wo[delayed_source_win].diff,
  'delayed restore clears ownerless diff state when source returns')
assert(vim.wo[delayed_source_win].wrap,
  'delayed restore restores source wrap when source returns')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = delayed_source_win }), '0',
  'delayed restore restores source foldcolumn when source returns')
vim.wait(50, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == restore_listeners_before
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), restore_listeners_before,
  'consumed restore ticket releases its shared listener')
vim.api.nvim_del_augroup_by_id(wipe_group)
vim.api.nvim_buf_delete(wipe_buffer, { force = true })
vim.cmd('only')
end

-- 较早的 BufWinEnter 回调返回前，successor 会先消费旧 restore ticket
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local ticket_listener_baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local ticket_second_source_win = vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local ticket_source_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(ticket_second_source_win, source_buf)
vim.api.nvim_win_set_buf(ticket_source_win, source_buf)

local ticket_a_ready
local ticket_b_ready
local ticket_starts = {}
local ticket_successor_armed = false
Git.show = function(_, ref, _, callback)
  ticket_starts[#ticket_starts + 1] = ref
  callback({ ref })
end
local ticket_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareTicketSuccessorTest', { clear = true })
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = ticket_group,
  buffer = source_buf,
  callback = function()
    if not ticket_successor_armed
        or vim.api.nvim_get_current_win() ~= ticket_source_win then
      return
    end
    ticket_successor_armed = false
    FileCompare.open('ticket-successor-B', {
      bufnr = source_buf,
      winid = ticket_source_win,
      root = '/repo',
      on_ready = function(context) ticket_b_ready = context end,
    })
  end,
})
assert(FileCompare.open('ticket-successor-A', {
  bufnr = source_buf,
  winid = ticket_source_win,
  root = '/repo',
  on_ready = function(context) ticket_a_ready = context end,
}))
vim.wait(50, function() return ticket_a_ready ~= nil end)

local ticket_replacement = vim.api.nvim_create_buf(false, true)
vim.bo[ticket_replacement].bufhidden = 'hide'
vim.api.nvim_win_set_buf(ticket_source_win, ticket_replacement)
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(ticket_a_ready.ref_win)
      and vim.w[ticket_source_win].vv_git_file_compare_owner == nil
end)
ticket_successor_armed = true
vim.api.nvim_win_set_buf(ticket_source_win, source_buf)
vim.wait(100, function() return ticket_b_ready ~= nil end)
assert_eq(vim.inspect(ticket_starts), vim.inspect({
  'ticket-successor-A',
  'ticket-successor-B',
}), 'a synchronous successor starts exactly once while the old ticket listener is pending')
assert(ticket_b_ready and vim.api.nvim_win_is_valid(ticket_b_ready.ref_win),
  'successor compare mounts after synchronously consuming the old restore ticket')
assert(vim.wo[ticket_source_win].diff,
  'old restore ticket cannot disable the successor source diff')
assert_eq(vim.api.nvim_get_option_value('foldmethod', { win = ticket_source_win }), 'diff',
  'old restore ticket cannot restore the successor fold method')

local ticket_b_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(ticket_b_ready.ref_win), function()
  ticket_b_close = vim.fn.maparg('q', 'n', false, true)
end)
ticket_b_close.callback()
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(ticket_b_ready.ref_win)
      and vim.w[ticket_source_win].vv_git_file_compare_owner == nil
end)

local noautocmd_a_ready
local noautocmd_b_ready
assert(FileCompare.open('ticket-noautocmd-A', {
  bufnr = source_buf,
  winid = ticket_source_win,
  root = '/repo',
  on_ready = function(context) noautocmd_a_ready = context end,
}))
vim.wait(50, function() return noautocmd_a_ready ~= nil end)
vim.api.nvim_win_set_buf(ticket_source_win, ticket_replacement)
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(noautocmd_a_ready.ref_win)
      and vim.w[ticket_source_win].vv_git_file_compare_owner == nil
end)
vim.api.nvim_win_call(ticket_source_win, function()
  vim.cmd('noautocmd buffer ' .. source_buf)
end)
assert(FileCompare.open('ticket-noautocmd-B', {
  bufnr = source_buf,
  winid = ticket_source_win,
  root = '/repo',
  on_ready = function(context) noautocmd_b_ready = context end,
}))
vim.wait(100, function() return noautocmd_b_ready ~= nil end)
assert(noautocmd_b_ready and vim.wo[ticket_source_win].diff,
  'new transaction actively consumes a ticket missed by noautocmd BufWinEnter')
assert_eq(vim.api.nvim_get_option_value('foldmethod', { win = ticket_source_win }), 'diff',
  'noautocmd ticket consumption happens before successor option snapshots')
local noautocmd_b_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(noautocmd_b_ready.ref_win), function()
  noautocmd_b_close = vim.fn.maparg('q', 'n', false, true)
end)
noautocmd_b_close.callback()
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(noautocmd_b_ready.ref_win)
      and vim.w[ticket_source_win].vv_git_file_compare_owner == nil
end)
vim.api.nvim_del_augroup_by_id(ticket_group)
vim.wait(50, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == ticket_listener_baseline
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), ticket_listener_baseline,
  'successor ticket consumption releases the shared restore listener')
vim.api.nvim_buf_delete(ticket_replacement, { force = true })
vim.cmd('only')
end

-- 只把焦点移到 ref 侧不会改变 source 窗口所有权
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local focus_ready
Git.show = function(_, _, _, callback) callback({ 'focus' }) end
assert(FileCompare.open('focus-ref', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) focus_ready = context end,
}))
vim.wait(50, function() return focus_ready ~= nil end)
vim.api.nvim_set_current_win(focus_ready.ref_win)
vim.wait(30)
assert(vim.api.nvim_win_is_valid(focus_ready.ref_win),
  'focus-only source -> ref transition keeps compare mounted')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 2,
  'focus-only transition preserves the two-window diff layout')
vim.api.nvim_win_close(focus_ready.ref_win, true)
vim.wait(50, function() return #vim.api.nvim_tabpage_list_wins(0) == 1 end)

-- ready compare 在可重入 cleanup 完成前始终保持 active transaction
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local cleanup_a_ready
local cleanup_b_ready
local cleanup_c_ready
Git.show = function(_, ref, _, callback) callback({ ref }) end
assert(FileCompare.open('cleanup-A', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) cleanup_a_ready = context end,
}))
vim.wait(50, function() return cleanup_a_ready ~= nil end)
vim.api.nvim_set_current_win(cleanup_a_ready.ref_win)
local cleanup_group = vim.api.nvim_create_augroup('VVGitFileCompareCleanupReentrantTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = cleanup_group,
  once = true,
  callback = function()
    FileCompare.open('cleanup-B', {
      bufnr = source_buf,
      root = '/repo',
      on_ready = function(context) cleanup_b_ready = context end,
    })
  end,
})
local cleanup_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(cleanup_a_ready.ref_win), function()
  cleanup_mapping = vim.fn.maparg('q', 'n', false, true)
end)
assert(type(cleanup_mapping.callback) == 'function', 'ready compare exposes its close mapping')
cleanup_mapping.callback()
vim.wait(100, function() return cleanup_b_ready ~= nil end)
assert(cleanup_b_ready and vim.api.nvim_win_is_valid(cleanup_b_ready.ref_win),
  'compare opened from cleanup WinEnter mounts after old cleanup finishes')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 2,
  'cleanup reentry leaves one source and one latest ref window')
vim.api.nvim_win_close(cleanup_b_ready.ref_win, true)
vim.wait(50, function() return #vim.api.nvim_tabpage_list_wins(0) == 1 end)
assert(FileCompare.open('cleanup-C', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) cleanup_c_ready = context end,
}))
vim.wait(50, function() return cleanup_c_ready ~= nil end)
assert(cleanup_c_ready and vim.api.nvim_win_is_valid(cleanup_c_ready.ref_win),
  'cleanup reentry cannot leave the transaction queue permanently stuck')
vim.api.nvim_win_close(cleanup_c_ready.ref_win, true)
vim.wait(50, function() return #vim.api.nvim_tabpage_list_wins(0) == 1 end)

-- 外部直接关闭 ref 时，barrier 会保持到 WinEnter 回调全部退出
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local direct_close_starts = {}
local direct_close_d_ready
local direct_close_errors = 0
Git.show = function(_, ref, _, callback)
  direct_close_starts[#direct_close_starts + 1] = ref
  callback({ ref })
end
local direct_close_a_ready
assert(FileCompare.open('direct-close-A', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) direct_close_a_ready = context end,
}))
vim.wait(50, function() return direct_close_a_ready ~= nil end)
vim.api.nvim_set_current_win(direct_close_a_ready.ref_win)
local direct_close_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareDirectCloseBarrierTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = direct_close_group,
  once = true,
  callback = function()
    for _, ref in ipairs({ 'direct-close-B', 'direct-close-C', 'direct-close-D' }) do
      FileCompare.open(ref, {
        bufnr = source_buf,
        winid = direct_close_a_ready.source_win,
        root = '/repo',
        on_ready = ref == 'direct-close-D'
            and function(context) direct_close_d_ready = context end
            or nil,
        on_error = function() direct_close_errors = direct_close_errors + 1 end,
      })
    end
  end,
})
vim.api.nvim_win_close(direct_close_a_ready.ref_win, true)
vim.wait(100, function() return direct_close_d_ready ~= nil end)
assert_eq(vim.inspect(direct_close_starts), vim.inspect({ 'direct-close-A', 'direct-close-D' }),
  'direct close drains only the latest reentrant intent after the close stack unwinds')
assert_eq(direct_close_errors, 0, 'direct close reentry never attempts a split during E242 close state')
assert(direct_close_d_ready and vim.api.nvim_win_is_valid(direct_close_d_ready.ref_win),
  'latest direct-close intent mounts successfully')
local direct_close_d_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(direct_close_d_ready.ref_win), function()
  direct_close_d_mapping = vim.fn.maparg('q', 'n', false, true)
end)
direct_close_d_mapping.callback()
vim.wait(50, function() return #vim.api.nvim_tabpage_list_wins(0) == 1 end)
end

-- 旧 queued starter 必须继续处理插入的 direct mount 所创建的最新 intent
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local drain_a_ready
local drain_d_ready
Git.show = function(_, ref, _, callback) callback({ ref }) end
assert(FileCompare.open('drain-A', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) drain_a_ready = context end,
}))
vim.wait(50, function() return drain_a_ready ~= nil end)
vim.api.nvim_set_current_win(drain_a_ready.ref_win)
local drain_b_group = vim.api.nvim_create_augroup('VVGitFileCompareDrainBTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = drain_b_group,
  once = true,
  callback = function() FileCompare.open('drain-B', { bufnr = source_buf, root = '/repo' }) end,
})
local drain_schedules = {}
vim.schedule = function(callback) drain_schedules[#drain_schedules + 1] = callback end
local drain_close_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(drain_a_ready.ref_win), function()
  drain_close_mapping = vim.fn.maparg('q', 'n', false, true)
end)
drain_close_mapping.callback()
assert_eq(#drain_schedules, 1, 'A cleanup queues exactly one B starter')

local drain_d_group = vim.api.nvim_create_augroup('VVGitFileCompareDrainDTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = drain_d_group,
  once = true,
  callback = function()
    FileCompare.open('drain-D', {
      bufnr = source_buf,
      root = '/repo',
      on_ready = function(context) drain_d_ready = context end,
    })
  end,
})
assert(FileCompare.open('drain-C', { bufnr = source_buf, root = '/repo' }))
assert_eq(#drain_schedules, 1, 'C cleanup cannot enqueue D while the stale B ticket exists')
drain_schedules[1]()
assert_eq(#drain_schedules, 2, 'stale B starter schedules a fresh drain for latest D')
drain_schedules[2]()
assert_eq(#drain_schedules, 3, 'D mount queues its ready callback')
drain_schedules[3]()
vim.schedule = original_schedule
assert(drain_d_ready and vim.api.nvim_win_is_valid(drain_d_ready.ref_win),
  'latest D starts after the stale B starter drains')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 2,
  'starter replacement leaves only source and latest D windows')
local drain_d_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(drain_d_ready.ref_win), function()
  drain_d_mapping = vim.fn.maparg('q', 'n', false, true)
end)
drain_d_mapping.callback()
vim.wait(50, function() return #vim.api.nvim_tabpage_list_wins(0) == 1 end)

-- source 解析本身可重入；latest-wins 由入口 request 决定，而非 bufload 返回顺序
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local resolve_starts = {}
local resolve_a_ready = 0
local resolve_c_ready
Git.show = function(_, ref, _, callback)
  resolve_starts[#resolve_starts + 1] = ref
  callback({ ref })
end
local resolve_group = vim.api.nvim_create_augroup('VVGitFileCompareResolveReentrantTest', { clear = true })
vim.api.nvim_create_autocmd('BufNewFile', {
  group = resolve_group,
  once = true,
  callback = function()
    FileCompare.open('resolve-C', {
      bufnr = source_buf,
      root = '/repo',
      on_ready = function(context) resolve_c_ready = context end,
    })
  end,
})
local missing_path = '/repo/vv-git-resolve-reentrant-' .. vim.uv.hrtime() .. '.lua'
assert(FileCompare.open('resolve-A', {
  path = missing_path,
  root = '/repo',
  on_ready = function() resolve_a_ready = resolve_a_ready + 1 end,
}))
vim.wait(100, function() return resolve_c_ready ~= nil end)
assert_eq(vim.inspect(resolve_starts), vim.inspect({ 'resolve-C' }),
  'stale resolving A never starts its producer after synchronous C')
assert_eq(resolve_a_ready, 0, 'stale resolving A never publishes ready')
assert(resolve_c_ready and vim.api.nvim_win_is_valid(resolve_c_ready.ref_win),
  'latest resolve-time request owns the mounted UI')
vim.api.nvim_win_close(resolve_c_ready.ref_win, true)
vim.wait(50, function()
  return #vim.api.nvim_tabpage_list_wins(0) == 1
      and vim.w[resolve_c_ready.source_win].vv_git_file_compare_owner == nil
end)

-- 任意 mount 异常都会回滚，并为下一个请求释放串行屏障
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local saved_open_win = vim.api.nvim_open_win
local saved_buf_delete = vim.api.nvim_buf_delete
local saved_mount_notify = vim.notify
local mount_errors = 0
local mount_delete_error = false
vim.notify = noop
vim.api.nvim_open_win = function(...)
  error('forced mount failure')
end
vim.api.nvim_buf_delete = function(buf, opts)
  if not mount_delete_error
      and vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_get_name(buf):match('/mount%-error/') then
    mount_delete_error = true
    error('forced transient ref buffer delete failure')
  end
  return saved_buf_delete(buf, opts)
end
assert(FileCompare.open('mount-error', {
  bufnr = source_buf,
  root = '/repo',
  on_error = function() mount_errors = mount_errors + 1 end,
}))
vim.api.nvim_open_win = saved_open_win
vim.api.nvim_buf_delete = saved_buf_delete
vim.notify = saved_mount_notify
vim.wait(50, function() return mount_errors == 1 end)
assert(mount_delete_error, 'mount rollback exercises transient ref buffer delete failure')
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(buf) then
    assert(not vim.api.nvim_buf_get_name(buf):match('/mount%-error/'),
      'mount rollback leaves no ref buffer or pending guard marker')
  end
end
local after_error_ready
assert(FileCompare.open('after-mount-error', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) after_error_ready = context end,
}))
vim.wait(50, function() return after_error_ready ~= nil end)
assert(after_error_ready and vim.api.nvim_win_is_valid(after_error_ready.ref_win),
  'mount exception finalizer releases the transaction for the next compare')
vim.api.nvim_win_close(after_error_ready.ref_win, true)
vim.wait(50, function()
  return #vim.api.nvim_tabpage_list_wins(0) == 1
      and vim.w[after_error_ready.source_win].vv_git_file_compare_owner == nil
end)
end

-- open_win 在副作用后抛错时仍会回滚其唯一且精确的 split
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local source_win = vim.api.nvim_get_current_win()
local unrelated_buf = vim.api.nvim_create_buf(false, true)
vim.bo[unrelated_buf].bufhidden = 'hide'
local created_win
local b_ready
Guard.uninstall()
assert(Guard.install(), 'post-effect rollback installs capture below the outer wrapper')
local real_open_win = vim.api.nvim_open_win
local injected = false
vim.api.nvim_open_win = function(...)
  local win = real_open_win(...)
  if not injected then
    injected = true
    created_win = win
    vim.api.nvim_win_set_buf(win, unrelated_buf)
    FileCompare.open('post-open-error-B', {
      bufnr = source_buf,
      winid = source_win,
      root = '/repo',
      on_ready = function(context) b_ready = context end,
    })
    vim.api.nvim_open_win = real_open_win
    error('forced outer wrapper failure after exact split creation')
  end
  return win
end
local saved_notify = vim.notify
vim.notify = noop
assert(FileCompare.open('post-open-error-A', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
}))
vim.api.nvim_open_win = real_open_win
vim.notify = saved_notify
vim.wait(100, function() return b_ready ~= nil end)
assert(injected, 'test injects an error after the production split already exists')
assert(created_win and not vim.api.nvim_win_is_valid(created_win),
  'rollback closes the unique split even after an outer wrapper changes its buffer')
assert(b_ready and vim.api.nvim_win_is_valid(b_ready.ref_win),
  'queued B mounts after the post-side-effect A failure')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 2,
  'post-side-effect failure leaves only source and B ref windows')
vim.api.nvim_win_close(b_ready.ref_win, true)
vim.wait(50, function()
  return #vim.api.nvim_tabpage_list_wins(0) == 1
      and vim.w[source_win].vv_git_file_compare_owner == nil
end)
vim.api.nvim_buf_delete(unrelated_buf, { force = true })
Guard.uninstall()
end

-- 未安装 Guard 时 mount 失败，也不得把带 token 的 source 推断为 ref
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local source_win = vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local peer_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(source_win)
local windows_before = #vim.api.nvim_tabpage_list_wins(0)
Guard.uninstall()
local real_open_win = vim.api.nvim_open_win
local errors = 0
vim.api.nvim_open_win = function() error('forced pre-side-effect open failure') end
local saved_notify = vim.notify
vim.notify = noop
assert(FileCompare.open('unguarded-open-error', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
  on_error = function() errors = errors + 1 end,
}))
vim.api.nvim_open_win = real_open_win
vim.notify = saved_notify
vim.wait(100, function() return errors == 1 end)
assert_eq(errors, 1, 'unguarded mount failure reaches the public error callback')
assert(vim.api.nvim_win_is_valid(source_win),
  'unguarded mount failure never closes the token-bearing source window')
assert(vim.api.nvim_win_is_valid(peer_win),
  'unguarded mount failure preserves the caller peer window')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), windows_before,
  'pre-side-effect failure preserves the complete caller layout')
vim.api.nvim_win_close(peer_win, true)
end

-- 安装在 Guard 下层的 wrapper 即使丢失 ref handle，也不能转移资源所有权
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local source_win = vim.api.nvim_get_current_win()
local unrelated_buf = vim.api.nvim_create_buf(false, true)
vim.bo[unrelated_buf].bufhidden = 'hide'
Guard.uninstall()
local native_open_win = vim.api.nvim_open_win
local created_win
local outer = function(...)
  created_win = native_open_win(...)
  vim.api.nvim_win_set_buf(created_win, unrelated_buf)
  error('forced wrapper-before-Guard post-effect failure')
end
vim.api.nvim_open_win = outer
assert(Guard.install(), 'ordering test installs Guard above the throwing wrapper')
local errors = 0
local saved_notify = vim.notify
vim.notify = noop
assert(FileCompare.open('guard-order-open-error', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
  on_error = function() errors = errors + 1 end,
}))
vim.notify = saved_notify
vim.wait(100, function() return errors == 1 end)
assert(vim.api.nvim_win_is_valid(source_win),
  'wrapper-before-Guard failure never closes the source window')
assert(created_win and vim.api.nvim_win_is_valid(created_win),
  'opaque post-effect failure leaves an unproven third-party window untouched')
Guard.uninstall()
vim.api.nvim_open_win = native_open_win
vim.api.nvim_win_close(created_win, true)
vim.api.nvim_buf_delete(unrelated_buf, { force = true })
end

-- 已消失的 ref 不能把所有权转移给唯一新增的第三方窗口
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local source_win = vim.api.nvim_get_current_win()
local unrelated_buf = vim.api.nvim_create_buf(false, true)
vim.bo[unrelated_buf].bufhidden = 'hide'
Guard.uninstall()
assert(Guard.install(), 'negative ownership test installs capture below the outer wrapper')
local guarded_open_win = vim.api.nvim_open_win
local created_ref
local unrelated_win
local b_ready
local injected = false
vim.api.nvim_open_win = function(...)
  local win = guarded_open_win(...)
  if not injected then
    injected = true
    created_ref = win
    vim.api.nvim_win_close(win, true)
    unrelated_win = guarded_open_win(unrelated_buf, true, {
      split = 'right',
      win = source_win,
      noautocmd = true,
    })
    FileCompare.open('post-open-owner-B', {
      bufnr = source_buf,
      winid = source_win,
      root = '/repo',
      on_ready = function(context) b_ready = context end,
    })
    vim.api.nvim_open_win = guarded_open_win
    error('forced outer failure after replacing the ref with a third-party window')
  end
  return win
end
local saved_notify = vim.notify
vim.notify = noop
assert(FileCompare.open('post-open-owner-A', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
}))
vim.api.nvim_open_win = guarded_open_win
vim.notify = saved_notify
vim.wait(100, function() return b_ready ~= nil end)
assert(created_ref and not vim.api.nvim_win_is_valid(created_ref),
  'outer wrapper really removes A exact ref before throwing: '
    .. vim.inspect({ created_ref = created_ref, injected = injected }))
assert(unrelated_win and vim.api.nvim_win_is_valid(unrelated_win),
  'A rollback never claims the unique third-party replacement window')
assert(b_ready and vim.api.nvim_win_is_valid(b_ready.ref_win),
  'queued B still mounts after the exact A ref disappeared')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 3,
  'source, third-party split, and B ref all retain their own ownership')
vim.api.nvim_win_close(b_ready.ref_win, true)
vim.wait(100, function() return vim.w[source_win].vv_git_file_compare_owner == nil end)
vim.api.nvim_win_close(unrelated_win, true)
vim.api.nvim_buf_delete(unrelated_buf, { force = true })
Guard.uninstall()
end

-- 即使 WinEnter 在同一 tab 创建其他 split，也只回滚 A 的精确 split handle
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local partial_source_win = vim.api.nvim_get_current_win()
local partial_split_b_ready
local partial_split_group = vim.api.nvim_create_augroup('VVGitFileComparePartialSplitTest', { clear = true })
local external_split
vim.api.nvim_create_autocmd('WinEnter', {
  group = partial_split_group,
  once = true,
  callback = function()
    vim.cmd('vsplit')
    external_split = vim.api.nvim_get_current_win()
    FileCompare.open('partial-split-B', {
      bufnr = source_buf,
      winid = partial_source_win,
      root = '/repo',
      on_ready = function(context) partial_split_b_ready = context end,
    })
    error('forced WinEnter failure after an unrelated split')
  end,
})
local partial_saved_notify = vim.notify
vim.notify = noop
assert(FileCompare.open('partial-split-A', { bufnr = source_buf, root = '/repo' }))
vim.notify = partial_saved_notify
vim.wait(100, function() return partial_split_b_ready ~= nil end)
assert(partial_split_b_ready and vim.api.nvim_win_is_valid(partial_split_b_ready.ref_win),
  'queued B mounts after A rolls back its exact split')
assert(vim.api.nvim_win_is_valid(external_split),
  'A rollback preserves the unrelated same-tab split')
assert_eq(#vim.api.nvim_tabpage_list_wins(0), 3,
  'only source, unrelated split, and B ref remain')
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  assert(not name:match('/partial%-split%-A/'), 'A exact ref window does not leak')
end
local partial_split_b_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(partial_split_b_ready.ref_win), function()
  partial_split_b_mapping = vim.fn.maparg('q', 'n', false, true)
end)
partial_split_b_mapping.callback()
vim.api.nvim_win_close(external_split, true)
vim.wait(50, function() return #vim.api.nvim_tabpage_list_wins(0) == 1 end)

-- 受控 split 创建会压制 WinNew 重入，并保留无关 tab
local cross_source_tab = vim.api.nvim_get_current_tabpage()
vim.cmd('tabnew')
local unrelated_tab = vim.api.nvim_get_current_tabpage()
local unrelated_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_tabpage(cross_source_tab)
local cross_tab_b_ready
local cross_tab_winnew = 0
local cross_tab_group = vim.api.nvim_create_augroup('VVGitFileCompareCrossTabSplitTest', { clear = true })
vim.api.nvim_create_autocmd('WinNew', {
  group = cross_tab_group,
  once = true,
  callback = function()
    cross_tab_winnew = cross_tab_winnew + 1
    vim.api.nvim_set_current_tabpage(unrelated_tab)
    error('controlled split must not run WinNew')
  end,
})
vim.notify = noop
assert(FileCompare.open('cross-tab-B', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) cross_tab_b_ready = context end,
}))
vim.notify = partial_saved_notify
vim.wait(100, function() return cross_tab_b_ready ~= nil end)
assert_eq(cross_tab_winnew, 0, 'controlled split does not expose a half-owned WinNew boundary')
assert(vim.api.nvim_tabpage_is_valid(unrelated_tab), 'rollback preserves the unrelated tab')
assert(vim.api.nvim_win_is_valid(unrelated_win), 'rollback preserves the unrelated current window')
assert_eq(#vim.api.nvim_tabpage_list_wins(cross_source_tab), 2,
  'controlled split creates exactly the source and ref windows')
local cross_tab_b_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(cross_tab_b_ready.ref_win), function()
  cross_tab_b_mapping = vim.fn.maparg('q', 'n', false, true)
end)
cross_tab_b_mapping.callback()
assert_eq(#vim.api.nvim_tabpage_list_wins(cross_source_tab), 1,
  'closing B restores the source tab one-window layout')
vim.api.nvim_set_current_tabpage(unrelated_tab)
vim.cmd('tabclose')
vim.api.nvim_set_current_tabpage(cross_source_tab)
vim.api.nvim_del_augroup_by_id(cross_tab_group)

-- 即使命名 API 在副作用后抛错，已命名 ref buffer 仍归 transaction 所有
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local function count_ref_buffers()
  local count = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_get_name(buf):match('^vv%-git://file/') then
      count = count + 1
    end
  end
  return count
end
local ref_buffers_before = count_ref_buffers()
local partial_buffer_b_ready
local saved_set_name = vim.api.nvim_buf_set_name
local injected_buffer_failure = false
vim.api.nvim_buf_set_name = function(buf, name)
  saved_set_name(buf, name)
  if not injected_buffer_failure and name:match('/partial%-buffer%-A/') then
    injected_buffer_failure = true
    FileCompare.open('partial-buffer-B', {
      bufnr = source_buf,
      root = '/repo',
      on_ready = function(context) partial_buffer_b_ready = context end,
    })
    error('forced buffer failure after naming')
  end
end
vim.notify = noop
assert(FileCompare.open('partial-buffer-A', { bufnr = source_buf, root = '/repo' }))
vim.api.nvim_buf_set_name = saved_set_name
vim.notify = partial_saved_notify
vim.wait(100, function() return partial_buffer_b_ready ~= nil end)
assert_eq(count_ref_buffers(), ref_buffers_before + 1,
  'failed A ref buffer is gone while mounted B owns exactly one ref buffer')
vim.api.nvim_win_close(partial_buffer_b_ready.ref_win, true)
vim.wait(50, function()
  return count_ref_buffers() == ref_buffers_before
      and vim.w[partial_buffer_b_ready.source_win].vv_git_file_compare_owner == nil
end)
assert_eq(count_ref_buffers(), ref_buffers_before, 'closing B leaves no partially named A buffer')

-- mapping 和 option 快照在 pending producer 返回后的 mount 阶段采集
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local pending_mapping_callback
local pending_mapping_ready
local old_pending_mapping_calls = 0
local new_pending_mapping_calls = 0
local old_pending_mapping = function() old_pending_mapping_calls = old_pending_mapping_calls + 1 end
local new_pending_mapping = function() new_pending_mapping_calls = new_pending_mapping_calls + 1 end
vim.keymap.set('n', 'q', old_pending_mapping, { buffer = source_buf })
vim.wo.wrap = false
Git.show = function(_, _, _, callback) pending_mapping_callback = callback end
assert(FileCompare.open('pending-mapping', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) pending_mapping_ready = context end,
}))
vim.keymap.set('n', 'q', new_pending_mapping, { buffer = source_buf })
vim.wo.wrap = true
pending_mapping_callback({ 'pending' })
vim.wait(50, function() return pending_mapping_ready ~= nil end)
local pending_close_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(pending_mapping_ready.ref_win), function()
  pending_close_mapping = vim.fn.maparg('q', 'n', false, true)
end)
pending_close_mapping.callback()
local restored_pending_mapping
vim.api.nvim_buf_call(source_buf, function()
  restored_pending_mapping = vim.fn.maparg('q', 'n', false, true)
end)
assert(type(restored_pending_mapping.callback) == 'function', 'pending-time mapping remains callable after close')
restored_pending_mapping.callback()
assert_eq(old_pending_mapping_calls, 0, 'producer-start mapping snapshot is not restored')
assert_eq(new_pending_mapping_calls, 1, 'pending-time mapping replacement is restored on close')
assert(vim.wo.wrap, 'pending-time window option replacement is restored on close')

-- pending listener 建立失败会被收敛，并立即释放 transaction
local saved_create_autocmd = vim.api.nvim_create_autocmd
local listener_failure_injected = false
local listener_error_count = 0
local listener_producer_starts = 0
Git.show = function(_, _, _, callback)
  listener_producer_starts = listener_producer_starts + 1
  callback({ 'listener' })
end
vim.api.nvim_create_autocmd = function(...)
  if not listener_failure_injected then
    listener_failure_injected = true
    error('forced pending listener failure')
  end
  return saved_create_autocmd(...)
end
vim.notify = noop
local listener_open_ok, listener_started = pcall(FileCompare.open, 'listener-error', {
  bufnr = source_buf,
  root = '/repo',
  on_error = function() listener_error_count = listener_error_count + 1 end,
})
vim.api.nvim_create_autocmd = saved_create_autocmd
vim.notify = partial_saved_notify
assert(listener_open_ok, 'pending listener failure does not escape the public open API')
assert_eq(listener_started, false, 'pending listener failure reports that no producer started')
assert_eq(listener_producer_starts, 0, 'listener failure prevents producer startup')
vim.wait(50, function() return listener_error_count == 1 end)
local listener_recovery_ready
assert(FileCompare.open('listener-recovery', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) listener_recovery_ready = context end,
}))
vim.wait(50, function() return listener_recovery_ready ~= nil end)
assert(listener_recovery_ready and vim.api.nvim_win_is_valid(listener_recovery_ready.ref_win),
  'listener setup failure releases active transaction for the next compare')
local listener_recovery_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(listener_recovery_ready.ref_win), function()
  listener_recovery_mapping = vim.fn.maparg('q', 'n', false, true)
end)
listener_recovery_mapping.callback()

-- ref 命名期间的 BufFilePost 重入会纳入 source mapping 快照
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local mount_old_mapping_calls = 0
local mount_new_mapping_calls = 0
local mount_old_mapping = function() mount_old_mapping_calls = mount_old_mapping_calls + 1 end
local mount_new_mapping = function() mount_new_mapping_calls = mount_new_mapping_calls + 1 end
vim.keymap.set('n', 'q', mount_old_mapping, { buffer = source_buf })
local mount_mapping_group = vim.api.nvim_create_augroup('VVGitFileCompareMountMappingTest', { clear = true })
vim.api.nvim_create_autocmd('BufFilePost', {
  group = mount_mapping_group,
  once = true,
  callback = function()
    vim.keymap.set('n', 'q', mount_new_mapping, { buffer = source_buf })
  end,
})
local mount_mapping_ready
Git.show = function(_, _, _, callback) callback({ 'mapping' }) end
assert(FileCompare.open('mount-mapping', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) mount_mapping_ready = context end,
}))
vim.wait(50, function() return mount_mapping_ready ~= nil end)
local mount_mapping_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(mount_mapping_ready.ref_win), function()
  mount_mapping_close = vim.fn.maparg('q', 'n', false, true)
end)
mount_mapping_close.callback()
local restored_mount_mapping
vim.api.nvim_buf_call(source_buf, function()
  restored_mount_mapping = vim.fn.maparg('q', 'n', false, true)
end)
restored_mount_mapping.callback()
assert_eq(mount_old_mapping_calls, 0, 'pre-BufFilePost mapping snapshot is not restored')
assert_eq(mount_new_mapping_calls, 1, 'BufFilePost mapping is restored after compare closes')

-- 内部 diff 建立不会暴露半挂载的 OptionSet 边界
do
vim.api.nvim_set_option_value('foldcolumn', '0', { win = vim.api.nvim_get_current_win() })
local mount_option_events = 0
local previous_state_tab = state.tabpage
state.tabpage = vim.api.nvim_get_current_tabpage()
Guard.uninstall()
assert(Guard.install(), 'mount option test installs the real vv-git open_win guard')
local mount_option_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareMountOptionBoundaryTest', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', {
  group = mount_option_group,
  pattern = 'diff',
  callback = function()
    mount_option_events = mount_option_events + 1
    vim.api.nvim_set_option_value('foldcolumn', '5', { win = vim.api.nvim_get_current_win() })
  end,
})
local mount_option_ready
assert(FileCompare.open('mount-option-boundary', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) mount_option_ready = context end,
}))
vim.wait(50, function() return mount_option_ready ~= nil end)
assert_eq(mount_option_events, 0,
  'controlled noautocmd diff setup cannot invoke third-party OptionSet mid-mount')
vim.api.nvim_del_augroup_by_id(mount_option_group)
local mount_option_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(mount_option_ready.ref_win), function()
  mount_option_close = vim.fn.maparg('q', 'n', false, true)
end)
mount_option_close.callback()
Guard.uninstall()
state.tabpage = previous_state_tab
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = mount_option_ready.source_win }), '0',
  'mount option cleanup restores the pre-compare value')
end

-- ready 阶段的 source option 写入不会被 ref 关闭时的自动 diff 恢复覆盖
vim.api.nvim_set_option_value('foldcolumn', '0', { win = vim.api.nvim_get_current_win() })
local option_listeners_before = #vim.api.nvim_get_autocmds({ event = 'OptionSet' })
local ready_option_context
assert(FileCompare.open('ready-option', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) ready_option_context = context end,
}))
vim.wait(50, function() return ready_option_context ~= nil end)
vim.api.nvim_set_option_value('foldcolumn', '5', { win = ready_option_context.source_win })
vim.api.nvim_win_close(ready_option_context.ref_win, true)
vim.wait(100, function()
  return vim.w[ready_option_context.source_win].vv_git_file_compare_owner == nil
      and vim.api.nvim_get_option_value('foldcolumn', { win = ready_option_context.source_win }) == '5'
end)
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = ready_option_context.source_win }), '5',
  'ready-time third-party foldcolumn survives direct ref close and scheduled cleanup')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'OptionSet' }), option_listeners_before,
  'direct ref close releases the transaction OptionSet listener')

-- Neovim 自动退出 diff mode 前会采样 non-nested WinEnter 写入
do
vim.api.nvim_set_option_value('foldcolumn', '0', { win = ready_option_context.source_win })
vim.api.nvim_set_option_value('wrap', true, { win = ready_option_context.source_win })
local nonnested_context
assert(FileCompare.open('nonnested-option', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) nonnested_context = context end,
}))
vim.wait(50, function() return nonnested_context ~= nil end)
vim.api.nvim_set_current_win(nonnested_context.ref_win)
local nonnested_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareNonnestedOptionTest', { clear = true })
vim.api.nvim_create_autocmd('WinEnter', {
  group = nonnested_group,
  once = true,
  callback = function()
    vim.api.nvim_set_option_value('foldcolumn', '6', { win = nonnested_context.source_win })
    -- diff mode 已经应用 false；write stamp 必须识别本次同值写入
    vim.api.nvim_set_option_value('wrap', false, { win = nonnested_context.source_win })
  end,
})
vim.api.nvim_win_close(nonnested_context.ref_win, true)
vim.wait(100, function()
  return vim.w[nonnested_context.source_win].vv_git_file_compare_owner == nil
end)
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = nonnested_context.source_win }), '6',
  'cleanup preserves an option write whose OptionSet was suppressed by outer WinEnter')
assert(not vim.api.nvim_get_option_value('wrap', { win = nonnested_context.source_win }),
  'write identity preserves a non-nested same-value wrap write')
end

-- OptionSet dirty identity 会保留第三方显式写入的 A → B → A 最终值
vim.api.nvim_set_option_value('foldcolumn', '7', { win = ready_option_context.source_win })
local option_aba_context
assert(FileCompare.open('option-aba', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) option_aba_context = context end,
}))
vim.wait(50, function() return option_aba_context ~= nil end)
local option_applied = vim.api.nvim_get_option_value('foldcolumn', { win = option_aba_context.source_win })
local option_alternate = option_applied == '5' and '6' or '5'
vim.api.nvim_set_option_value('foldcolumn', option_alternate, { win = option_aba_context.source_win })
vim.api.nvim_set_option_value('foldcolumn', option_applied, { win = option_aba_context.source_win })
local option_aba_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(option_aba_context.ref_win), function()
  option_aba_close = vim.fn.maparg('q', 'n', false, true)
end)
option_aba_close.callback()
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = option_aba_context.source_win }), option_applied,
  'ready-time option ABA preserves the explicit third-party final value')

-- 同一调用点的同值 OptionSet 仍会记录显式 source 所有权
do
local function set_wrap(win, value)
  vim.api.nvim_set_option_value('wrap', value, { win = win, scope = 'local' })
end
set_wrap(option_aba_context.source_win, true)
local same_stamp_context
assert(FileCompare.open('same-stamp-option', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) same_stamp_context = context end,
}))
vim.wait(50, function() return same_stamp_context ~= nil end)
set_wrap(same_stamp_context.source_win, false)
local same_stamp_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(same_stamp_context.ref_win), function()
  same_stamp_close = vim.fn.maparg('q', 'n', false, true)
end)
same_stamp_close.callback()
assert(not vim.api.nvim_get_option_value('wrap', { win = same_stamp_context.source_win }),
  'source-target OptionSet preserves an explicit same-line same-value write')
end

-- 后注册的 OptionSet listener 可同步替换首次观察到的值
do
for _, close_kind in ipairs({ 'q', 'direct-source', 'direct-ref' }) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = 0 })
  local final_write_context
  Git.show = function(_, _, _, callback) callback({ close_kind }) end
  assert(FileCompare.open('final-option-' .. close_kind, {
    bufnr = source_buf,
    root = '/repo',
    on_ready = function(context) final_write_context = context end,
  }))
  vim.wait(50, function() return final_write_context ~= nil end)

  local final_write_fired = false
  local final_write_group = vim.api.nvim_create_augroup(
    'VVGitFileCompareFinalOptionTest' .. close_kind, { clear = true })
  vim.api.nvim_create_autocmd('OptionSet', {
    group = final_write_group,
    pattern = 'foldcolumn',
    once = true,
    callback = function()
      final_write_fired = true
      vim.api.nvim_set_option_value(
        'foldcolumn',
        '6',
        { win = final_write_context.source_win }
      )
    end,
  })
  vim.api.nvim_set_option_value('foldcolumn', '5', { win = final_write_context.source_win })
  assert(final_write_fired, close_kind .. ' executes the later synchronous option writer')
  assert_eq(vim.api.nvim_get_option_value('foldcolumn', {
    win = final_write_context.source_win,
  }), '6', close_kind .. ' reaches the third-party final option before cleanup')

  if close_kind == 'q' then
    local final_write_close
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(final_write_context.ref_win), function()
      final_write_close = vim.fn.maparg('q', 'n', false, true)
    end)
    final_write_close.callback()
  else
    vim.api.nvim_set_current_win(
      close_kind == 'direct-source'
          and final_write_context.source_win
          or final_write_context.ref_win
    )
    vim.api.nvim_win_close(final_write_context.ref_win, true)
  end
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(final_write_context.ref_win)
        and vim.w[final_write_context.source_win].vv_git_file_compare_owner == nil
  end)
  assert_eq(vim.api.nvim_get_option_value('foldcolumn', {
    win = final_write_context.source_win,
  }), '6', close_kind .. ' preserves the final synchronous option writer')
  pcall(vim.api.nvim_del_augroup_by_id, final_write_group)
end
end

-- WinClosed unwind 期间的显式写入会覆盖关闭前冻结的快照
do
for _, close_kind in ipairs({ 'q', 'direct-source', 'direct-ref' }) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = 0 })
  local unwind_context
  Git.show = function(_, _, _, callback) callback({ close_kind }) end
  assert(FileCompare.open('unwind-option-' .. close_kind, {
    bufnr = source_buf,
    root = '/repo',
    on_ready = function(context) unwind_context = context end,
  }))
  vim.wait(50, function() return unwind_context ~= nil end)
  vim.api.nvim_set_option_value('foldcolumn', '5', { win = unwind_context.source_win })

  local unwind_fired = 0
  local unwind_group = vim.api.nvim_create_augroup(
    'VVGitFileCompareUnwindOptionTest' .. close_kind, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = unwind_group,
    pattern = tostring(unwind_context.ref_win),
    once = true,
    callback = function()
      unwind_fired = unwind_fired + 1
      vim.api.nvim_set_option_value('foldcolumn', '6', { win = unwind_context.source_win })
      assert_eq(vim.api.nvim_get_option_value('foldcolumn', {
        win = unwind_context.source_win,
      }), '6', close_kind .. ' reaches the post-freeze unwind value')
    end,
  })

  if close_kind == 'q' then
    local unwind_close
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(unwind_context.ref_win), function()
      unwind_close = vim.fn.maparg('q', 'n', false, true)
    end)
    unwind_close.callback()
  else
    vim.api.nvim_set_current_win(
      close_kind == 'direct-source'
          and unwind_context.source_win
          or unwind_context.ref_win
    )
    vim.api.nvim_win_close(unwind_context.ref_win, true)
  end
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(unwind_context.ref_win)
        and vim.w[unwind_context.source_win].vv_git_file_compare_owner == nil
  end)
  assert_eq(unwind_fired, 1, close_kind .. ' executes one post-freeze WinClosed writer')
  assert_eq(vim.api.nvim_get_option_value('foldcolumn', {
    win = unwind_context.source_win,
  }), '6', close_kind .. ' preserves the post-freeze WinClosed writer')
  pcall(vim.api.nvim_del_augroup_by_id, unwind_group)
end
end

-- freeze 后的同值 OptionSet 仍代表显式最终 owner
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
vim.api.nvim_set_option_value('wrap', true, { win = 0 })
local post_freeze_same_context
Git.show = function(_, _, _, callback) callback({ 'post-freeze-same' }) end
assert(FileCompare.open('post-freeze-same', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) post_freeze_same_context = context end,
}))
vim.wait(50, function() return post_freeze_same_context ~= nil end)
local post_freeze_events = 0
local function set_post_freeze_wrap()
  vim.api.nvim_set_option_value('wrap', false, { win = post_freeze_same_context.source_win })
end
local post_freeze_group = vim.api.nvim_create_augroup(
  'VVGitFileComparePostFreezeSameTest', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', {
  group = post_freeze_group,
  pattern = 'wrap',
  callback = function() post_freeze_events = post_freeze_events + 1 end,
})
vim.api.nvim_create_autocmd('WinClosed', {
  group = post_freeze_group,
  pattern = tostring(post_freeze_same_context.ref_win),
  once = true,
  callback = set_post_freeze_wrap,
})
local post_freeze_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(post_freeze_same_context.ref_win), function()
  post_freeze_close = vim.fn.maparg('q', 'n', false, true)
end)
post_freeze_close.callback()
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(post_freeze_same_context.ref_win)
      and vim.w[post_freeze_same_context.source_win].vv_git_file_compare_owner == nil
end)
assert(post_freeze_events > 0, 'post-freeze same-value writer emits a real OptionSet event')
assert(not vim.api.nvim_get_option_value('wrap', { win = post_freeze_same_context.source_win }),
  'post-freeze same-value writer survives cleanup')
vim.api.nvim_del_augroup_by_id(post_freeze_group)
end

-- WinClosed 期间注册的 WinEnter writer 会在 cleanup capture listener 后执行
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
vim.api.nvim_set_option_value('foldcolumn', '0', { win = 0 })
local late_enter_context
Git.show = function(_, _, _, callback) callback({ 'late-enter-option' }) end
assert(FileCompare.open('late-enter-option', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) late_enter_context = context end,
}))
vim.wait(50, function() return late_enter_context ~= nil end)
vim.api.nvim_set_option_value('foldcolumn', '5', { win = late_enter_context.source_win })
local late_enter_fired = 0
local late_enter_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareLateEnterOptionTest', { clear = true })
local real_create_autocmd = vim.api.nvim_create_autocmd
local late_enter_injected = false
vim.api.nvim_create_autocmd = function(event, opts)
  local id = real_create_autocmd(event, opts)
  if not late_enter_injected and event == 'WinEnter' and opts.once then
    late_enter_injected = true
    real_create_autocmd('WinEnter', {
      group = late_enter_group,
      once = true,
      callback = function()
        late_enter_fired = late_enter_fired + 1
        vim.api.nvim_set_option_value(
          'foldcolumn',
          '6',
          { win = late_enter_context.source_win }
        )
      end,
    })
  end
  return id
end
local late_enter_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(late_enter_context.ref_win), function()
  late_enter_close = vim.fn.maparg('q', 'n', false, true)
end)
vim.api.nvim_set_current_win(late_enter_context.ref_win)
late_enter_close.callback()
vim.api.nvim_create_autocmd = real_create_autocmd
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(late_enter_context.ref_win)
      and vim.w[late_enter_context.source_win].vv_git_file_compare_owner == nil
end)
assert(late_enter_injected, 'test registers the writer after the cleanup capture listener')
assert_eq(late_enter_fired, 1, 'late WinEnter writer runs after the capture listener')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', {
  win = late_enter_context.source_win,
}), '6', 'late WinEnter writer survives final option restoration')
vim.api.nvim_del_augroup_by_id(late_enter_group)
end

-- 关闭 FileCompare 不能拆散调用方原本持有的 diff group
do
for _, close_kind in ipairs({ 'q', 'direct-source', 'direct-ref' }) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  local existing_source_win = vim.api.nvim_get_current_win()
  vim.cmd('vsplit')
  local existing_peer_win = vim.api.nvim_get_current_win()
  local existing_peer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(existing_peer_win, existing_peer_buf)
  for _, win in ipairs({ existing_source_win, existing_peer_win }) do
    vim.api.nvim_win_call(win, function() vim.cmd('diffthis') end)
  end

  local existing_diff_context
  Git.show = function(_, _, _, callback) callback({ close_kind }) end
  assert(FileCompare.open('existing-diff-' .. close_kind, {
    bufnr = source_buf,
    winid = existing_source_win,
    root = '/repo',
    on_ready = function(context) existing_diff_context = context end,
  }))
  vim.wait(50, function() return existing_diff_context ~= nil end)
  assert(vim.api.nvim_get_option_value('diff', { win = existing_source_win }),
    close_kind .. ' keeps the pre-existing source in diff while mounted')
  assert(vim.api.nvim_get_option_value('diff', { win = existing_peer_win }),
    close_kind .. ' keeps the caller-owned peer in diff while mounted')

  if close_kind == 'q' then
    local existing_diff_close
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(existing_diff_context.ref_win), function()
      existing_diff_close = vim.fn.maparg('q', 'n', false, true)
    end)
    existing_diff_close.callback()
  else
    vim.api.nvim_set_current_win(
      close_kind == 'direct-source' and existing_source_win or existing_diff_context.ref_win
    )
    vim.api.nvim_win_close(existing_diff_context.ref_win, true)
  end
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(existing_diff_context.ref_win)
        and vim.w[existing_source_win].vv_git_file_compare_owner == nil
  end)
  assert(vim.api.nvim_get_option_value('diff', { win = existing_source_win }),
    close_kind .. ' preserves the caller-owned source diff state')
  assert(vim.api.nvim_get_option_value('diff', { win = existing_peer_win }),
    close_kind .. ' preserves the caller-owned peer diff state')

  for _, win in ipairs({ existing_source_win, existing_peer_win }) do
    vim.api.nvim_win_call(win, function() vim.cmd('noautocmd diffoff') end)
  end
  vim.api.nvim_win_close(existing_peer_win, true)
  vim.api.nvim_buf_delete(existing_peer_buf, { force = true })
end
end

-- 关闭 FileCompare 唯一 peer 后，调用方持有的孤立 diff 状态仍会保留
do
for _, close_kind in ipairs({ 'q', 'direct-source', 'direct-ref' }) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  local isolated_source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(isolated_source_win, function() vim.cmd('diffthis') end)
  assert(vim.api.nvim_get_option_value('diff', { win = isolated_source_win }),
    close_kind .. ' starts from a caller-owned isolated diff state')

  local isolated_context
  Git.show = function(_, _, _, callback) callback({ close_kind }) end
  assert(FileCompare.open('isolated-diff-' .. close_kind, {
    bufnr = source_buf,
    winid = isolated_source_win,
    root = '/repo',
    on_ready = function(context) isolated_context = context end,
  }))
  vim.wait(50, function() return isolated_context ~= nil end)
  if close_kind == 'q' then
    local isolated_close
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(isolated_context.ref_win), function()
      isolated_close = vim.fn.maparg('q', 'n', false, true)
    end)
    isolated_close.callback()
  else
    vim.api.nvim_set_current_win(
      close_kind == 'direct-source' and isolated_source_win or isolated_context.ref_win
    )
    vim.api.nvim_win_close(isolated_context.ref_win, true)
  end
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(isolated_context.ref_win)
        and vim.w[isolated_source_win].vv_git_file_compare_owner == nil
  end)
  assert(vim.api.nvim_get_option_value('diff', { win = isolated_source_win }),
    close_kind .. ' restores the caller-owned isolated diff state')
  vim.api.nvim_win_call(isolated_source_win, function() vim.cmd('noautocmd diffoff') end)
end
end

-- freeze 后显式写入的 diff=false 会覆盖调用方持有的孤立 diff=true
do
for _, close_kind in ipairs({ 'q', 'direct-source', 'direct-ref' }) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(source_win, function() vim.cmd('diffthis') end)

  local context
  Git.show = function(_, _, _, callback) callback({ close_kind }) end
  assert(FileCompare.open('isolated-explicit-diffoff-' .. close_kind, {
    bufnr = source_buf,
    winid = source_win,
    root = '/repo',
    on_ready = function(current) context = current end,
  }))
  vim.wait(50, function() return context ~= nil end)
  local writer_calls = 0
  local group = vim.api.nvim_create_augroup(
    'VVGitFileCompareIsolatedExplicitDiff' .. close_kind, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(context.ref_win),
    once = true,
    callback = function()
      writer_calls = writer_calls + 1
      vim.api.nvim_set_option_value('diff', false, { win = source_win })
    end,
  })

  if close_kind == 'q' then
    local close
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(context.ref_win), function()
      close = vim.fn.maparg('q', 'n', false, true)
    end)
    close.callback()
  else
    vim.api.nvim_set_current_win(close_kind == 'direct-source' and source_win or context.ref_win)
    vim.api.nvim_win_close(context.ref_win, true)
  end
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(context.ref_win)
        and vim.w[source_win].vv_git_file_compare_owner == nil
  end)
  assert_eq(writer_calls, 1, close_kind .. ' executes the post-freeze diff writer')
  assert_eq(vim.api.nvim_get_option_value('diff', { win = source_win }), false,
    close_kind .. ' preserves the explicit post-freeze diff=false')
  vim.api.nvim_del_augroup_by_id(group)
end
end

-- ready 阶段显式写入的 diff=false 在所有关闭路径中始终归外部 owner
do
for _, close_kind in ipairs({ 'q', 'direct-source', 'direct-ref' }) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(source_win, function() vim.cmd('diffthis') end)
  local context
  Git.show = function(_, _, _, callback) callback({ close_kind }) end
  assert(FileCompare.open('ready-explicit-diffoff-' .. close_kind, {
    bufnr = source_buf,
    winid = source_win,
    root = '/repo',
    on_ready = function(current) context = current end,
  }))
  vim.wait(50, function() return context ~= nil end)
  vim.api.nvim_set_option_value('diff', false, { win = source_win })
  assert_eq(vim.api.nvim_get_option_value('diff', { win = source_win }), false,
    close_kind .. ' records explicit diff=false before close')
  if close_kind == 'q' then
    local close
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(context.ref_win), function()
      close = vim.fn.maparg('q', 'n', false, true)
    end)
    close.callback()
  else
    vim.api.nvim_set_current_win(close_kind == 'direct-source' and source_win or context.ref_win)
    vim.api.nvim_win_close(context.ref_win, true)
  end
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(context.ref_win)
        and vim.w[source_win].vv_git_file_compare_owner == nil
  end)
  assert_eq(vim.api.nvim_get_option_value('diff', { win = source_win }), false,
    close_kind .. ' preserves ready-time explicit diff=false')
end
end

-- FileCompare 之前注册的 WinClosed writer 持有最终 diff 值
do
for _, close_kind in ipairs({ 'q', 'direct-source', 'direct-ref' }) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_call(source_win, function() vim.cmd('diffthis') end)
  local context
  local armed = false
  local writer_calls = 0
  local group = vim.api.nvim_create_augroup(
    'VVGitFileCompareEarlierDiffWriter' .. close_kind, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    once = true,
    callback = function(args)
      if armed and tonumber(args.match) == context.ref_win then
        writer_calls = writer_calls + 1
        vim.api.nvim_set_option_value('diff', false, { win = source_win })
      end
    end,
  })
  Git.show = function(_, _, _, callback) callback({ close_kind }) end
  assert(FileCompare.open('earlier-explicit-diffoff-' .. close_kind, {
    bufnr = source_buf,
    winid = source_win,
    root = '/repo',
    on_ready = function(current) context = current end,
  }))
  vim.wait(50, function() return context ~= nil end)
  armed = true
  if close_kind == 'q' then
    local close
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(context.ref_win), function()
      close = vim.fn.maparg('q', 'n', false, true)
    end)
    close.callback()
  else
    vim.api.nvim_set_current_win(close_kind == 'direct-source' and source_win or context.ref_win)
    vim.api.nvim_win_close(context.ref_win, true)
  end
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(context.ref_win)
        and vim.w[source_win].vv_git_file_compare_owner == nil
  end)
  assert_eq(writer_calls, 1, close_kind .. ' executes the earlier WinClosed writer')
  assert_eq(vim.api.nvim_get_option_value('diff', { win = source_win }), false,
    close_kind .. ' preserves earlier WinClosed explicit diff=false')
  vim.api.nvim_del_augroup_by_id(group)
end
end

-- 受控 teardown 完成后，真实的 freeze 后 diff 写入归外部所有
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local explicit_diff_source_win = vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local explicit_diff_peer_win = vim.api.nvim_get_current_win()
local explicit_diff_peer_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(explicit_diff_peer_win, explicit_diff_peer_buf)
for _, win in ipairs({ explicit_diff_source_win, explicit_diff_peer_win }) do
  vim.api.nvim_win_call(win, function() vim.cmd('diffthis') end)
end

local explicit_diff_context
Git.show = function(_, _, _, callback) callback({ 'explicit-diff' }) end
assert(FileCompare.open('explicit-post-freeze-diff', {
  bufnr = source_buf,
  winid = explicit_diff_source_win,
  root = '/repo',
  on_ready = function(context) explicit_diff_context = context end,
}))
vim.wait(50, function() return explicit_diff_context ~= nil end)
local explicit_diff_events = 0
local explicit_diff_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareExplicitPostFreezeDiffTest', { clear = true })
vim.api.nvim_create_autocmd('WinClosed', {
  group = explicit_diff_group,
  pattern = tostring(explicit_diff_context.ref_win),
  once = true,
  callback = function()
    explicit_diff_events = explicit_diff_events + 1
    vim.api.nvim_set_option_value('diff', false, { win = explicit_diff_source_win })
  end,
})
local explicit_diff_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(explicit_diff_context.ref_win), function()
  explicit_diff_close = vim.fn.maparg('q', 'n', false, true)
end)
vim.api.nvim_set_current_win(explicit_diff_source_win)
explicit_diff_close.callback()
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(explicit_diff_context.ref_win)
      and vim.w[explicit_diff_source_win].vv_git_file_compare_owner == nil
end)
assert_eq(explicit_diff_events, 1, 'post-freeze explicit diff writer executes once')
assert_eq(vim.api.nvim_get_option_value('diff', { win = explicit_diff_source_win }), false,
  'post-freeze explicit diff=false overrides the pre-existing source state')
pcall(vim.api.nvim_win_call, explicit_diff_peer_win, function() vim.cmd('noautocmd diffoff') end)
vim.api.nvim_win_close(explicit_diff_peer_win, true)
vim.api.nvim_buf_delete(explicit_diff_peer_buf, { force = true })
vim.api.nvim_del_augroup_by_id(explicit_diff_group)
end

-- non-nested OptionSet 可能压制 buffer 事件，因此稍后会复核精确 owner
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local option_replace_context
Git.show = function(_, _, _, callback) callback({ 'option-replace' }) end
assert(FileCompare.open('option-replace-source', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) option_replace_context = context end,
}))
vim.wait(50, function() return option_replace_context ~= nil end)

local replacement_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(replacement_buf, 0, -1, false, { 'unsaved replacement' })
vim.bo[replacement_buf].bufhidden = 'wipe'
vim.bo[replacement_buf].modified = true
local replace_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareOptionReplaceTest', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', {
  group = replace_group,
  pattern = 'foldcolumn',
  once = true,
  callback = function()
    vim.api.nvim_win_set_buf(option_replace_context.source_win, replacement_buf)
  end,
})
vim.api.nvim_set_option_value('foldcolumn', '5', { win = option_replace_context.source_win })
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(option_replace_context.ref_win)
      and vim.w[option_replace_context.source_win].vv_git_file_compare_owner == nil
end)
assert(vim.api.nvim_buf_is_valid(replacement_buf),
  'owner recheck does not wipe the caller-owned replacement buffer')
assert_eq(vim.api.nvim_win_get_buf(option_replace_context.source_win), replacement_buf,
  'owner recheck does not replace the caller-owned buffer')
assert_eq(vim.api.nvim_buf_get_lines(replacement_buf, 0, -1, false)[1], 'unsaved replacement',
  'owner recheck preserves unsaved replacement contents')
vim.bo[replacement_buf].bufhidden = 'hide'
vim.api.nvim_win_set_buf(option_replace_context.source_win, source_buf)
vim.api.nvim_buf_delete(replacement_buf, { force = true })
vim.api.nvim_del_augroup_by_id(replace_group)
end

-- 无论 listener 顺序或 option 名称如何，都先校验 owner，再判断 option 归属
do
for _, case in ipairs({
  { name = 'early-diff-option', option = 'foldcolumn', value = '5', expected = '5' },
  { name = 'early-same-value-option', option = 'wrap', value = false, expected = false },
  { name = 'early-unrelated-option', option = 'number', value = true },
}) do
  vim.cmd('only')
  vim.api.nvim_win_set_buf(0, source_buf)
  local early_source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value('wrap', true, { win = early_source_win })
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = early_source_win })
  local early_replacement = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(early_replacement, 0, -1, false, { 'early-unsaved-X' })
  vim.bo[early_replacement].bufhidden = 'wipe'
  vim.bo[early_replacement].modified = true

  local early_armed = false
  local early_fired = 0
  local early_group = vim.api.nvim_create_augroup(
    'VVGitFileCompareOwnerOrderTest' .. case.name, { clear = true })
  vim.api.nvim_create_autocmd('OptionSet', {
    group = early_group,
    pattern = case.option,
    callback = function()
      if not early_armed then return end
      early_fired = early_fired + 1
      vim.api.nvim_win_set_buf(early_source_win, early_replacement)
    end,
  })

  local early_context
  Git.show = function(_, _, _, callback) callback({ case.name }) end
  assert(FileCompare.open(case.name, {
    bufnr = source_buf,
    root = '/repo',
    on_ready = function(context) early_context = context end,
  }))
  vim.wait(50, function() return early_context ~= nil end)
  early_armed = true
  vim.api.nvim_set_option_value(case.option, case.value, { win = early_source_win })
  early_armed = false
  vim.wait(100, function()
    return not vim.api.nvim_win_is_valid(early_context.ref_win)
        and vim.w[early_source_win].vv_git_file_compare_owner == nil
  end)
  assert_eq(early_fired, 1, case.name .. ' executes the earlier replacement handler')
  assert(not vim.api.nvim_win_is_valid(early_context.ref_win),
    case.name .. ' closes stale ref UI after the scheduled exact-owner check')
  assert(vim.api.nvim_buf_is_valid(early_replacement),
    case.name .. ' preserves the caller-owned wipe buffer')
  assert_eq(vim.api.nvim_win_get_buf(early_source_win), early_replacement,
    case.name .. ' leaves the replacement in its owner window')
  assert_eq(vim.api.nvim_buf_get_lines(early_replacement, 0, -1, false)[1], 'early-unsaved-X',
    case.name .. ' preserves unsaved replacement contents')

  vim.bo[early_replacement].bufhidden = 'hide'
  vim.api.nvim_win_set_buf(early_source_win, source_buf)
  if case.expected ~= nil then
    assert_eq(vim.api.nvim_get_option_value(case.option, { win = early_source_win }), case.expected,
      case.name .. ' restores the explicit source option when the source returns')
  end
  vim.api.nvim_buf_delete(early_replacement, { force = true })
  vim.api.nvim_del_augroup_by_id(early_group)
end
end

-- 更早的无关 OptionSet handler 可能在当前 handler 执行前切换当前窗口
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local unrelated_source_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_option_value('foldcolumn', '0', { win = unrelated_source_win })
vim.cmd('vsplit')
local unrelated_win = vim.api.nvim_get_current_win()
local unrelated_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(unrelated_win, unrelated_buf)

local unrelated_armed = false
local unrelated_switched = 0
local unrelated_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareUnrelatedOptionTest', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', {
  group = unrelated_group,
  pattern = 'foldcolumn',
  callback = function()
    if not unrelated_armed then return end
    unrelated_switched = unrelated_switched + 1
    vim.api.nvim_set_current_win(unrelated_source_win)
  end,
})

local unrelated_context
Git.show = function(_, _, _, callback) callback({ 'unrelated-option' }) end
assert(FileCompare.open('unrelated-option', {
  bufnr = source_buf,
  winid = unrelated_source_win,
  root = '/repo',
  on_ready = function(context) unrelated_context = context end,
}))
vim.wait(50, function() return unrelated_context ~= nil end)
unrelated_armed = true
vim.api.nvim_set_option_value('foldcolumn', '9', { win = unrelated_win })
unrelated_armed = false
assert_eq(unrelated_switched, 1, 'earlier unrelated handler switches current window once')

local unrelated_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(unrelated_context.ref_win), function()
  unrelated_close = vim.fn.maparg('q', 'n', false, true)
end)
unrelated_close.callback()
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(unrelated_context.ref_win)
      and vim.w[unrelated_source_win].vv_git_file_compare_owner == nil
end)
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = unrelated_source_win }), '0',
  'unrelated event cannot claim the FileCompare source snapshot')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = unrelated_win }), '9',
  'unrelated window retains its own option value')
vim.api.nvim_del_augroup_by_id(unrelated_group)
vim.api.nvim_win_close(unrelated_win, true)
vim.api.nvim_buf_delete(unrelated_buf, { force = true })
end

-- 单个 option setter 在副作用后失败，不能跳过后续 option 恢复
do
vim.api.nvim_set_option_value('foldcolumn', '0', { win = option_aba_context.source_win })
local setter_error_context
assert(FileCompare.open('setter-post-error', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) setter_error_context = context end,
}))
vim.wait(50, function() return setter_error_context ~= nil end)
vim.api.nvim_set_option_value('foldcolumn', '5', { win = setter_error_context.source_win })
local real_set_option = vim.api.nvim_set_option_value
local setter_error_injected = false
vim.api.nvim_set_option_value = function(option, value, opts)
  real_set_option(option, value, opts)
  if not setter_error_injected
      and option == 'diff'
      and opts.win == setter_error_context.source_win then
    setter_error_injected = true
    error('forced post-side-effect option error')
  end
end
local setter_error_notify = vim.notify
vim.notify = noop
local setter_error_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(setter_error_context.ref_win), function()
  setter_error_close = vim.fn.maparg('q', 'n', false, true)
end)
setter_error_close.callback()
vim.api.nvim_set_option_value = real_set_option
vim.notify = setter_error_notify
assert(setter_error_injected, 'test injects a real post-side-effect setter failure')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = setter_error_context.source_win }), '5',
  'later desired options are restored after one setter reports an error')
assert(vim.w[setter_error_context.source_win].vv_git_file_compare_owner == nil,
  'setter error still releases compare ownership')
end

-- listener 瞬时删除失败会在忘记 handle 前重试
do
local listener_count_before = #vim.api.nvim_get_autocmds({ event = 'OptionSet' })
local listener_delete_context
assert(FileCompare.open('listener-delete-error', {
  bufnr = source_buf,
  root = '/repo',
  on_ready = function(context) listener_delete_context = context end,
}))
vim.wait(50, function() return listener_delete_context ~= nil end)
local real_delete_autocmd = vim.api.nvim_del_autocmd
local listener_delete_injected = false
vim.api.nvim_del_autocmd = function(id)
  if not listener_delete_injected then
    listener_delete_injected = true
    error('forced transient listener delete failure')
  end
  return real_delete_autocmd(id)
end
local listener_delete_close
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(listener_delete_context.ref_win), function()
  listener_delete_close = vim.fn.maparg('q', 'n', false, true)
end)
listener_delete_close.callback()
vim.api.nvim_del_autocmd = real_delete_autocmd
assert(listener_delete_injected, 'test injects a before-side-effect listener delete failure')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'OptionSet' }), listener_count_before,
  'listener delete retry leaves no stale transaction closure')
end

-- shared listener 部分创建失败会回滚全部 handle，包括瞬时删除失败
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local win = vim.api.nvim_get_current_win()
local desired = FileCompareWinopts.save(win)
local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = 'hide'
vim.api.nvim_win_set_buf(win, replacement)

local real_create = vim.api.nvim_create_autocmd
local real_delete = vim.api.nvim_del_autocmd
local create_calls = 0
local first_id
local delete_failures = 0
vim.api.nvim_create_autocmd = function(events, opts)
  create_calls = create_calls + 1
  if create_calls == 2 then error('forced second shared-listener creation failure') end
  local id = real_create(events, opts)
  first_id = first_id or id
  return id
end
vim.api.nvim_del_autocmd = function(id)
  if id == first_id and delete_failures < 2 then
    delete_failures = delete_failures + 1
    error('forced transient rollback delete failure')
  end
  return real_delete(id)
end
local transaction = {
  source_win = win,
  source = { bufnr = source_buf },
  source_desired_winopts = desired,
}
FileCompareWinopts.defer_restore(transaction)
vim.api.nvim_create_autocmd = real_create
vim.api.nvim_del_autocmd = real_delete
vim.wait(100, function()
  return first_id and #vim.api.nvim_get_autocmds({ id = first_id }) == 0
end)
assert(transaction.cleanup_error, 'partial listener creation reports its cleanup error')
assert_eq(delete_failures, 2, 'test reaches the verified asynchronous delete retry')
assert_eq(#vim.api.nvim_get_autocmds({ id = first_id }), 0,
  'partial listener creation leaves no untracked autocmd closure')
vim.api.nvim_win_set_buf(win, source_buf)
vim.api.nvim_buf_delete(replacement, { force = true })
end

-- 旧 handle 正在停止时，新 restore ticket 会重建完整 listener 集合
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local win = vim.api.nvim_get_current_win()
local baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local replacement = vim.api.nvim_create_buf(false, true)
local second_source = vim.api.nvim_create_buf(true, false)
vim.bo[replacement].bufhidden = 'hide'
vim.api.nvim_buf_set_name(second_source, '/repo/restore-listener-second.lua')
vim.api.nvim_win_set_buf(win, replacement)

local desired_first = FileCompareWinopts.save(win)
desired_first.wrap = true
local desired_second = vim.deepcopy(desired_first)
desired_second.wrap = false
desired_second.foldcolumn = '7'
FileCompareWinopts.defer_restore({
  source_win = win,
  source = { bufnr = source_buf },
  source_desired_winopts = desired_first,
})

local real_delete = vim.api.nvim_del_autocmd
local injected = 0
local second_registered = false
vim.api.nvim_del_autocmd = function(id)
  local entries = vim.api.nvim_get_autocmds({ id = id })
  local is_buffer_delete = false
  for _, entry in ipairs(entries) do
    if entry.event == 'BufDelete' or entry.event == 'BufWipeout' then
      is_buffer_delete = true
      break
    end
  end
  if is_buffer_delete and injected < 2 then
    injected = injected + 1
    if not second_registered then
      second_registered = true
      FileCompareWinopts.defer_restore({
        source_win = win,
        source = { bufnr = second_source },
        source_desired_winopts = desired_second,
      })
    end
    error('forced old listener delete failure during replacement registration')
  end
  return real_delete(id)
end
vim.api.nvim_win_set_buf(win, source_buf)
vim.api.nvim_del_autocmd = real_delete
assert(second_registered, 'new restore ticket is registered while the old set is stopping')
vim.api.nvim_win_set_buf(win, second_source)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  'replacement listener set consumes the new restore ticket')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '7',
  'replacement listener set retains every required restore event')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  'old and replacement shared listener sets are both released')
vim.api.nvim_win_set_buf(win, source_buf)
vim.api.nvim_buf_delete(replacement, { force = true })
vim.api.nvim_buf_delete(second_source, { force = true })
end

-- defer_restore 同步重入会复用正在创建的 listener 集合
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local win = vim.api.nvim_get_current_win()
local baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local replacement = vim.api.nvim_create_buf(false, true)
local second_source = vim.api.nvim_create_buf(true, false)
vim.bo[replacement].bufhidden = 'hide'
vim.api.nvim_buf_set_name(second_source, '/repo/restore-listener-reentrant.lua')
vim.api.nvim_win_set_buf(win, replacement)
local desired = FileCompareWinopts.save(win)
local second_desired = vim.deepcopy(desired)
second_desired.wrap = false
second_desired.foldcolumn = '6'

local real_create = vim.api.nvim_create_autocmd
local created_ids = {}
local reentered = false
vim.api.nvim_create_autocmd = function(events, opts)
  local id = real_create(events, opts)
  created_ids[#created_ids + 1] = id
  if not reentered then
    reentered = true
    FileCompareWinopts.defer_restore({
      source_win = win,
      source = { bufnr = second_source },
      source_desired_winopts = second_desired,
    })
  end
  return id
end
FileCompareWinopts.defer_restore({
  source_win = win,
  source = { bufnr = source_buf },
  source_desired_winopts = desired,
})
vim.api.nvim_create_autocmd = real_create
assert(reentered, 'test reenters after the first listener creation side effect')
assert_eq(#created_ids, 3, 'reentrant ticket reuses one complete listener set')
vim.api.nvim_win_set_buf(win, source_buf)
vim.api.nvim_win_set_buf(win, second_source)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  'reentrant ticket restores wrap through the shared listener set')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '6',
  'reentrant ticket restores foldcolumn through the shared listener set')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
for _, id in ipairs(created_ids) do
  assert_eq(#vim.api.nvim_get_autocmds({ id = id }), 0,
    'every listener created by the outer transaction is released')
end
vim.api.nvim_win_set_buf(win, source_buf)
vim.api.nvim_buf_delete(replacement, { force = true })
vim.api.nvim_buf_delete(second_source, { force = true })
end

-- 外层创建失败不能删除同 target 的 successor restore ticket
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local win = vim.api.nvim_get_current_win()
local baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = 'hide'
vim.api.nvim_win_set_buf(win, replacement)
local first_desired = FileCompareWinopts.save(win)
first_desired.wrap = true
first_desired.foldcolumn = '1'
local successor_desired = vim.deepcopy(first_desired)
successor_desired.wrap = false
successor_desired.foldcolumn = '8'

local real_create = vim.api.nvim_create_autocmd
local create_calls = 0
local reentered = false
vim.api.nvim_create_autocmd = function(events, opts)
  create_calls = create_calls + 1
  if create_calls == 2 then error('forced listener failure after same-target successor') end
  local id = real_create(events, opts)
  if not reentered then
    reentered = true
    FileCompareWinopts.defer_restore({
      source_win = win,
      source = { bufnr = source_buf },
      source_desired_winopts = successor_desired,
    })
  end
  return id
end
local first = {
  source_win = win,
  source = { bufnr = source_buf },
  source_desired_winopts = first_desired,
}
FileCompareWinopts.defer_restore(first)
vim.api.nvim_create_autocmd = real_create
assert(reentered, 'listener creation reenters with a same-target successor ticket')
assert(first.cleanup_error, 'outer ticket reports the injected listener creation failure')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline + 1
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline + 1,
  'scheduled reconcile builds one complete successor listener set')
vim.api.nvim_win_set_buf(win, source_buf)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  'same-target successor preserves its latest wrap value')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '8',
  'same-target successor preserves its latest foldcolumn value')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  'same-target successor listener set is released after consumption')
vim.api.nvim_buf_delete(replacement, { force = true })
end

-- 同 target 的立即恢复会取代 listener 仍在创建的旧 ticket
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local win = vim.api.nvim_get_current_win()
local baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = 'hide'
vim.api.nvim_win_set_buf(win, replacement)
local first_desired = FileCompareWinopts.save(win)
first_desired.wrap = true
first_desired.foldcolumn = '3'
local successor_desired = vim.deepcopy(first_desired)
successor_desired.wrap = false
successor_desired.foldcolumn = '8'

local real_create = vim.api.nvim_create_autocmd
local reentered = false
vim.api.nvim_create_autocmd = function(events, opts)
  if not reentered then
    reentered = true
    vim.api.nvim_win_set_buf(win, source_buf)
    FileCompareWinopts.defer_restore({
      source_win = win,
      source = { bufnr = source_buf },
      source_desired_winopts = successor_desired,
    })
  end
  return real_create(events, opts)
end
FileCompareWinopts.defer_restore({
  source_win = win,
  source = { bufnr = source_buf },
  source_desired_winopts = first_desired,
})
vim.api.nvim_create_autocmd = real_create
assert(reentered, 'listener creation reenters before the first real listener exists')
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  'immediate successor applies its latest wrap value')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '8',
  'immediate successor applies its latest foldcolumn value')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  'superseded outer ticket leaves no shared restore listener')
vim.api.nvim_win_set_buf(win, replacement)
vim.api.nvim_win_set_buf(win, source_buf)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  'superseded outer ticket cannot later restore its old wrap value')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '8',
  'superseded outer ticket cannot later restore its old foldcolumn value')
vim.api.nvim_buf_delete(replacement, { force = true })
end

-- 立即恢复被中断后会保留 listener，直到精确 target 返回
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_option_value('diff', false, { win = source_win, scope = 'local' })
vim.api.nvim_set_option_value('wrap', true, { win = source_win, scope = 'local' })
vim.api.nvim_set_option_value('foldcolumn', '0', { win = source_win, scope = 'local' })
local baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local a_ready
Git.show = function(_, ref, _, callback) callback({ ref }) end
assert(FileCompare.open('interrupted-restore-A', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
  on_ready = function(context) a_ready = context end,
}))
vim.wait(50, function() return a_ready ~= nil end)

local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = 'hide'
local switched = false
local switch_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareInterruptedImmediateRestoreTest', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', {
  group = switch_group,
  pattern = 'diff',
  once = true,
  callback = function()
    switched = true
    vim.api.nvim_win_set_buf(source_win, replacement)
  end,
})
local close_a
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(a_ready.ref_win), function()
  close_a = vim.fn.maparg('q', 'n', false, true)
end)
close_a.callback()
vim.wait(100, function()
  return switched
      and vim.api.nvim_win_get_buf(source_win) == replacement
      and not vim.api.nvim_win_is_valid(a_ready.ref_win)
      and vim.w[source_win].vv_git_file_compare_owner == nil
      and #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline + 1
end)
assert(switched, 'a real restore OptionSet synchronously replaces the source buffer')
assert_eq(vim.api.nvim_win_get_buf(source_win), replacement,
  'interrupted cleanup does not switch away the replacement buffer')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline + 1,
  'interrupted immediate restore keeps one shared listener for its ticket')

vim.api.nvim_win_set_buf(source_win, source_buf)
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
vim.api.nvim_set_option_value('wrap', false, { win = source_win, scope = 'local' })
vim.api.nvim_set_option_value('foldcolumn', '5', { win = source_win, scope = 'local' })
local b_ready
assert(FileCompare.open('interrupted-restore-B', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
  on_ready = function(context) b_ready = context end,
}))
vim.wait(50, function() return b_ready ~= nil end)
local close_b
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(b_ready.ref_win), function()
  close_b = vim.fn.maparg('q', 'n', false, true)
end)
close_b.callback()
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(b_ready.ref_win)
      and vim.w[source_win].vv_git_file_compare_owner == nil
      and #vim.api.nvim_tabpage_list_wins(0) == 1
end)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = source_win }), false,
  'a consumed A ticket cannot overwrite the user wrap value after B')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = source_win }), '5',
  'a consumed A ticket cannot overwrite the user foldcolumn after B')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  'interrupted restore listeners are released after the exact target returns')
vim.api.nvim_del_augroup_by_id(switch_group)
vim.api.nvim_buf_delete(replacement, { force = true })
end

-- listener 激活时会对账首个 listener 建立前已经返回的 target
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_option_value('diff', false, { win = source_win, scope = 'local' })
vim.api.nvim_set_option_value('wrap', true, { win = source_win, scope = 'local' })
vim.api.nvim_set_option_value('foldcolumn', '0', { win = source_win, scope = 'local' })
local baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local a_ready
Git.show = function(_, ref, _, callback) callback({ ref }) end
assert(FileCompare.open('listener-reconcile-A', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
  on_ready = function(context) a_ready = context end,
}))
vim.wait(50, function() return a_ready ~= nil end)

local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = 'hide'
local switched_away = false
local returned_before_listener = false
local switch_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareListenerReconcileTest', { clear = true })
vim.api.nvim_create_autocmd('OptionSet', {
  group = switch_group,
  pattern = 'diff',
  once = true,
  callback = function()
    switched_away = true
    vim.api.nvim_win_set_buf(source_win, replacement)
  end,
})
local real_create = vim.api.nvim_create_autocmd
vim.api.nvim_create_autocmd = function(events, opts)
  if events == 'BufWinEnter' and switched_away and not returned_before_listener then
    returned_before_listener = true
    vim.api.nvim_win_set_buf(source_win, source_buf)
  end
  return real_create(events, opts)
end
local close_a
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(a_ready.ref_win), function()
  close_a = vim.fn.maparg('q', 'n', false, true)
end)
close_a.callback()
vim.api.nvim_create_autocmd = real_create
vim.wait(100, function()
  return returned_before_listener
      and not vim.api.nvim_win_is_valid(a_ready.ref_win)
      and vim.w[source_win].vv_git_file_compare_owner == nil
      and #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
assert(switched_away, 'restore OptionSet moves the exact target away')
assert(returned_before_listener, 'the target returns before the first shared listener is registered')
assert_eq(vim.api.nvim_win_get_buf(source_win), source_buf,
  'listener activation reconciliation keeps the returned target current')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  'activation reconciliation consumes the ticket and releases its listeners')

vim.api.nvim_set_option_value('wrap', false, { win = source_win, scope = 'local' })
vim.api.nvim_set_option_value('foldcolumn', '5', { win = source_win, scope = 'local' })
local b_ready
assert(FileCompare.open('listener-reconcile-B', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
  on_ready = function(context) b_ready = context end,
}))
vim.wait(50, function() return b_ready ~= nil end)
local close_b
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(b_ready.ref_win), function()
  close_b = vim.fn.maparg('q', 'n', false, true)
end)
close_b.callback()
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(b_ready.ref_win)
      and vim.w[source_win].vv_git_file_compare_owner == nil
      and #vim.api.nvim_tabpage_list_wins(0) == 1
end)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = source_win }), false,
  'reconciled A ticket cannot overwrite the user wrap value after B')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = source_win }), '5',
  'reconciled A ticket cannot overwrite the user foldcolumn after B')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  'listener activation reconciliation leaves no shared listener')
vim.api.nvim_del_augroup_by_id(switch_group)
vim.api.nvim_buf_delete(replacement, { force = true })
end

-- target 在 WinClosed listener 建立前关闭时，listener 激活会丢弃对应 ticket
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
vim.cmd('vsplit')
local target_win = vim.api.nvim_get_current_win()
local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = 'hide'
vim.api.nvim_win_set_buf(target_win, replacement)
local desired = FileCompareWinopts.save(target_win)
local baseline = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' })
local closed_before_listener = false
local real_create = vim.api.nvim_create_autocmd
vim.api.nvim_create_autocmd = function(events, opts)
  if events == 'BufWinEnter' and not closed_before_listener then
    closed_before_listener = true
    vim.api.nvim_win_close(target_win, true)
  end
  return real_create(events, opts)
end
FileCompareWinopts.defer_restore({
  source_win = target_win,
  source = { bufnr = source_buf },
  source_desired_winopts = desired,
})
vim.api.nvim_create_autocmd = real_create
assert(closed_before_listener, 'target closes before the shared WinClosed listener exists')
assert(not vim.api.nvim_win_is_valid(target_win), 'listener activation preserves the closed target state')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  'activation reconciliation drops the invalid ticket and releases its listeners')
vim.api.nvim_buf_delete(replacement, { force = true })
end

-- nested successor 会在首个 setter 后废弃外层 deferred-restore attempt
do
vim.cmd('only')
vim.api.nvim_win_set_buf(0, source_buf)
local peer_win = vim.api.nvim_get_current_win()
vim.cmd('vsplit')
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(peer_win, source_buf)
vim.api.nvim_win_set_buf(source_win, source_buf)
local a_ready
Git.show = function(_, ref, _, callback) callback({ ref }) end
assert(FileCompare.open('restore-attempt-A', {
  bufnr = source_buf,
  winid = source_win,
  root = '/repo',
  on_ready = function(context) a_ready = context end,
}))
vim.wait(50, function() return a_ready ~= nil end)
local replacement = vim.api.nvim_create_buf(false, true)
vim.bo[replacement].bufhidden = 'hide'
vim.api.nvim_win_set_buf(source_win, replacement)
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(a_ready.ref_win)
      and vim.w[source_win].vv_git_file_compare_owner == nil
end)

local real_set_option = vim.api.nvim_set_option_value
local armed = true
local b_ready
vim.api.nvim_set_option_value = function(option, value, opts)
  real_set_option(option, value, opts)
  if armed and opts.win == source_win then
    armed = false
    FileCompare.open('restore-attempt-B', {
      bufnr = source_buf,
      winid = source_win,
      root = '/repo',
      on_ready = function(context) b_ready = context end,
    })
  end
end
vim.api.nvim_win_set_buf(source_win, source_buf)
vim.api.nvim_set_option_value = real_set_option
vim.wait(100, function() return b_ready ~= nil end)
assert(b_ready and vim.api.nvim_win_is_valid(b_ready.ref_win),
  'successor compare mounts from inside the old restore setter')
assert(vim.api.nvim_get_option_value('diff', { win = source_win }),
  'old restore attempt cannot disable successor diff')
assert(vim.api.nvim_get_option_value('scrollbind', { win = source_win }),
  'old restore attempt cannot disable successor scroll binding')
assert(vim.api.nvim_get_option_value('cursorbind', { win = source_win }),
  'old restore attempt cannot disable successor cursor binding')
assert_eq(vim.api.nvim_get_option_value('foldmethod', { win = source_win }), 'diff',
  'old restore attempt cannot restore successor fold method')
assert_eq(vim.api.nvim_get_option_value('wrap', { win = source_win }), false,
  'old restore attempt cannot restore successor wrap')
vim.api.nvim_win_close(b_ready.ref_win, true)
vim.wait(100, function()
  return vim.w[source_win].vv_git_file_compare_owner == nil
      and #vim.api.nvim_tabpage_list_wins(0) == 2
end)
vim.api.nvim_buf_delete(replacement, { force = true })
vim.api.nvim_win_close(peer_win, true)
end

-- 不可见的 opts.bufnr 会临时替换当前 buffer，并在关闭时恢复
vim.cmd('only')
local previous_visible = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, previous_visible)
local invisible_source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(invisible_source, '/repo/invisible.lua')
vim.bo[invisible_source].filetype = 'lua'

local invisible_reentrant_ready
local invisible_reentrant_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareInvisibleReentrantTest', { clear = true })
vim.api.nvim_create_autocmd('BufEnter', {
  group = invisible_reentrant_group,
  buffer = invisible_source,
  once = true,
  callback = function()
    FileCompare.open('B-invisible-reentrant', {
      bufnr = invisible_source,
      root = '/repo',
      on_ready = function(context) invisible_reentrant_ready = context end,
    })
  end,
})
Git.show = function(_, _, _, callback) callback({ 'old' }) end
assert(FileCompare.open('A-invisible-reentrant', {
  bufnr = invisible_source,
  root = '/repo',
}))
vim.wait(100, function() return invisible_reentrant_ready ~= nil end)
assert(invisible_reentrant_ready and #vim.api.nvim_tabpage_list_wins(0) == 2,
  'invisible-buffer reentrant mount is serialized onto the original layout')
vim.api.nvim_win_close(invisible_reentrant_ready.ref_win, true)
vim.wait(50, function()
  return vim.api.nvim_win_get_buf(invisible_reentrant_ready.source_win) == previous_visible
end)
assert_eq(vim.api.nvim_win_get_buf(invisible_reentrant_ready.source_win), previous_visible,
  'reentrant invisible compare restores the buffer visible before A started')

-- 恢复不可见 source 可通过 BufEnter 重入；新 owner 会等待 cleanup 完成
local cleanup_invisible_b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(cleanup_invisible_b, '/repo/invisible-cleanup-b.lua')
vim.bo[cleanup_invisible_b].filetype = 'lua'
local cleanup_invisible_a_ready
local cleanup_invisible_b_ready
assert(FileCompare.open('cleanup-invisible-A', {
  bufnr = invisible_source,
  root = '/repo',
  on_ready = function(context) cleanup_invisible_a_ready = context end,
}))
vim.wait(50, function() return cleanup_invisible_a_ready ~= nil end)
vim.api.nvim_set_current_win(cleanup_invisible_a_ready.ref_win)
local cleanup_invisible_group = vim.api.nvim_create_augroup(
  'VVGitFileCompareInvisibleCleanupTest', { clear = true })
vim.api.nvim_create_autocmd('BufEnter', {
  group = cleanup_invisible_group,
  buffer = previous_visible,
  once = true,
  callback = function()
    FileCompare.open('cleanup-invisible-B', {
      bufnr = cleanup_invisible_b,
      root = '/repo',
      on_ready = function(context) cleanup_invisible_b_ready = context end,
    })
  end,
})
local cleanup_invisible_mapping
vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(cleanup_invisible_a_ready.ref_win), function()
  cleanup_invisible_mapping = vim.fn.maparg('q', 'n', false, true)
end)
cleanup_invisible_mapping.callback()
vim.wait(100, function() return cleanup_invisible_b_ready ~= nil end)
assert(cleanup_invisible_b_ready and vim.api.nvim_win_is_valid(cleanup_invisible_b_ready.ref_win),
  'BufEnter cleanup reentry mounts after the old invisible source is restored')
assert(vim.w[cleanup_invisible_b_ready.source_win].vv_git_file_compare_owner ~= nil,
  'old cleanup cannot clear the new invisible compare owner token')
vim.api.nvim_win_close(cleanup_invisible_b_ready.ref_win, true)
vim.wait(50, function()
  return vim.api.nvim_win_get_buf(cleanup_invisible_b_ready.source_win) == previous_visible
end)
assert_eq(vim.api.nvim_win_get_buf(cleanup_invisible_b_ready.source_win), previous_visible,
  'closing cleanup-reentrant B restores the pre-A visible buffer')

local invisible_ready
assert(FileCompare.open('HEAD', {
  bufnr = invisible_source,
  root = '/repo',
  on_ready = function(context) invisible_ready = context end,
}))
vim.wait(50, function() return invisible_ready ~= nil end)
assert_eq(vim.api.nvim_win_get_buf(invisible_ready.source_win), invisible_source,
  'invisible source buffer is mounted into the owner window')
vim.api.nvim_win_close(invisible_ready.ref_win, true)
vim.wait(50, function() return vim.api.nvim_win_get_buf(invisible_ready.source_win) == previous_visible end)
assert_eq(vim.api.nvim_win_get_buf(invisible_ready.source_win), previous_visible,
  'closing compare restores the exact previous buffer')

local wipe_source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(wipe_source, '/repo/wipe.lua')
vim.api.nvim_win_set_buf(invisible_ready.source_win, wipe_source)
local wipe_ready
assert(FileCompare.open('HEAD', {
  bufnr = wipe_source,
  root = '/repo',
  on_ready = function(context) wipe_ready = context end,
}))
vim.wait(50, function() return wipe_ready ~= nil end)
vim.api.nvim_buf_delete(wipe_source, { force = true })
assert(not vim.api.nvim_buf_is_valid(wipe_source), 'source buffer is wiped by the test')
vim.wait(50, function()
  return not vim.api.nvim_win_is_valid(wipe_ready.ref_win)
      or vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wipe_ready.ref_win)) == ''
end)
if vim.api.nvim_win_is_valid(wipe_ready.ref_win) then
  assert_eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wipe_ready.ref_win)), '',
    'only remaining window no longer contains compare UI after source wipe')
  assert(not vim.wo[wipe_ready.ref_win].diff, 'only remaining window leaves diff mode after source wipe')
  assert(vim.w[wipe_ready.ref_win].vv_git_file_compare_owner == nil,
    'only remaining window releases compare ownership after source wipe')
end

Git.show = original_show
UGit.root = original_root
State.clear()
print('vv-git request scopes: PASS')
