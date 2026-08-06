-- vv-git FileCompare 延迟恢复与不可见 buffer 回归

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  .. '/helpers/request_scope.lua')
local assert_eq = H.assert_eq
local noop = H.noop
local FileCompare = require('vv-git.file_compare')
local FileCompareWinopts = require('vv-git.file_compare.winopts')
local Git = require('vv-git.git')
local State = require('vv-git.state')
local UGit = require('vv-utils.git')
local source_buf = H.create_file_compare_fixture()
local original_show = Git.show
local original_root = UGit.root
Git.show = function(_, _, _, callback) callback({ 'content' }) end
UGit.root = function() return '/repo' end

-- 单个 option setter 在副作用后失败，不能跳过后续 option 恢复
do
vim.api.nvim_set_option_value('foldcolumn', '0', { win = vim.api.nvim_get_current_win() })
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
print('vv-git request scopes file compare restore: PASS')
