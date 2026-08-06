-- vv-git FileCompare mount 与 UI 所有权回归

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  .. '/helpers/request_scope.lua')
local assert_eq = H.assert_eq
local noop = H.noop
local FileCompare = require('vv-git.file_compare')
local Git = require('vv-git.git')
local Guard = require('vv-git.guard')
local UGit = require('vv-utils.git')
local original_schedule = vim.schedule

-- File compare 遵循 latest-wins，并保留 source 窗口与 tab 快照
local original_show = Git.show
local original_root = UGit.root
local pending_shows = {}
Git.show = function(_, ref, _, callback) pending_shows[ref] = callback end

local source_buf = H.create_file_compare_fixture()
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
assert_eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ref_windows[1]), 0, -1, false)[1], 'new',
  'the only mounted ref keeps the latest request payload')

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

Git.show = original_show
UGit.root = original_root
print('vv-git request scopes file compare mount: PASS')
