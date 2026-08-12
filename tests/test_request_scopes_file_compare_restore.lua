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
assert(setter_error_injected, '测试注入真实的后置副作用设置器失败')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = setter_error_context.source_win }), '5',
  '单个 setter 失败后，仍恢复后续期望的选项')
assert(vim.w[setter_error_context.source_win].vv_git_file_compare_owner == nil,
  'setter 失败后仍释放 compare 所有权')
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
assert(listener_delete_injected, '测试注入真实的前置监听器删除失败')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'OptionSet' }), listener_count_before,
  '监听器删除重试后不遗留过期的 transaction closure')
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
assert(transaction.cleanup_error, '部分监听器创建报告其清理错误')
assert_eq(delete_failures, 2, '达到预期的异步 delete 重试')
assert_eq(#vim.api.nvim_get_autocmds({ id = first_id }), 0,
  '部分监听器创建后不保留未跟踪的 autocmd closure')
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
assert(second_registered, '旧集合停止时会注册新的恢复票据')
vim.api.nvim_win_set_buf(win, second_source)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  '替换的监听器集合消费新的恢复票据')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '7',
  '替换的监听器集合保留全部必需恢复事件')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  '旧与新的共享监听器集合都已释放')
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
assert(reentered, '首个监听器创建副作用后会重入')
assert_eq(#created_ids, 3, '重入票据复用完整监听器集合')
vim.api.nvim_win_set_buf(win, source_buf)
vim.api.nvim_win_set_buf(win, second_source)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  '重入票据通过共享监听器集合恢复 wrap')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '6',
  '重入票据通过共享监听器集合恢复 foldcolumn')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
for _, id in ipairs(created_ids) do
  assert_eq(#vim.api.nvim_get_autocmds({ id = id }), 0,
    '外层事务创建的所有监听器都已释放')
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
assert(reentered, '同目标监听器创建会重入并生成后继票据')
assert(first.cleanup_error, '外层票据报告了注入的监听器创建失败')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline + 1
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline + 1,
  '异步对账构建了一套完整后继监听器集合')
vim.api.nvim_win_set_buf(win, source_buf)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  '同目标后继者保留最新 wrap 值')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '8',
  '同目标后继者保留最新 foldcolumn 值')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  '同目标后继者的监听器集合在消费后被释放')
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
assert(reentered, '在首个真实监听器创建前先发生重入')
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  '立即后继写入最新 wrap')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '8',
  '立即后继写入最新 foldcolumn')
vim.wait(100, function()
  return #vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }) == baseline
end)
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  '被替代外层票据不保留共享恢复监听器')
vim.api.nvim_win_set_buf(win, replacement)
vim.api.nvim_win_set_buf(win, source_buf)
assert_eq(vim.api.nvim_get_option_value('wrap', { win = win }), false,
  '被替代外层票据后续不能恢复旧 wrap')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = win }), '8',
  '被替代外层票据后续不能恢复旧 foldcolumn')
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
assert(switched, '真实恢复的 OptionSet 会同步替换源 buffer')
assert_eq(vim.api.nvim_win_get_buf(source_win), replacement,
  '中断的 cleanup 不会切走 replacement buffer')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline + 1,
  '中断即时恢复持有一个共享监听器到票据')

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
  '已消费 A 的票据不能在 B 后覆盖用户 wrap')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = source_win }), '5',
  '已消费 A 的票据不能在 B 后覆盖用户 foldcolumn')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  '中断恢复的监听器在目标返回后释放')
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
assert(switched_away, '恢复 OptionSet 先将目标移出')
assert(returned_before_listener, '首个共享监听器注册前目标已返回')
assert_eq(vim.api.nvim_win_get_buf(source_win), source_buf,
  '监听器激活对账后仍保持返回目标为当前')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  '激活对账消费票据并释放其监听器')

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
  '对账后的 A 票据不能在 B 后覆盖用户 wrap')
assert_eq(vim.api.nvim_get_option_value('foldcolumn', { win = source_win }), '5',
  '对账后的 A 票据不能在 B 后覆盖用户 foldcolumn')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  '监听器激活对账后不保留共享监听器')
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
assert(closed_before_listener, '在共享 WinClosed 监听器建立前目标已关闭')
assert(not vim.api.nvim_win_is_valid(target_win), '监听器激活保留已关闭目标状态')
assert_eq(#vim.api.nvim_get_autocmds({ event = 'BufWinEnter' }), baseline,
  '激活对账丢弃无效票据并释放其监听器')
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
  '后继 compare 在旧恢复 setter 内挂载')
assert(vim.api.nvim_get_option_value('diff', { win = source_win }),
  '旧恢复尝试不能关闭后继者的 diff')
assert(vim.api.nvim_get_option_value('scrollbind', { win = source_win }),
  '旧恢复尝试不能关闭后继者的 scrollbind')
assert(vim.api.nvim_get_option_value('cursorbind', { win = source_win }),
  '旧恢复尝试不能关闭后继者的 cursorbind')
assert_eq(vim.api.nvim_get_option_value('foldmethod', { win = source_win }), 'diff',
  '旧恢复尝试不能恢复后继者的 foldmethod')
assert_eq(vim.api.nvim_get_option_value('wrap', { win = source_win }), false,
  '旧恢复尝试不能恢复后继者的 wrap')
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
  '不可见 buffer 的重入挂载按原布局串行执行')
vim.api.nvim_win_close(invisible_reentrant_ready.ref_win, true)
vim.wait(50, function()
  return vim.api.nvim_win_get_buf(invisible_reentrant_ready.source_win) == previous_visible
end)
assert_eq(vim.api.nvim_win_get_buf(invisible_reentrant_ready.source_win), previous_visible,
  '重入 invisible compare 恢复 A 开始前可见的 buffer')

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
  'BufEnter cleanup 重入在旧 invisible source 恢复后再挂载')
assert(vim.w[cleanup_invisible_b_ready.source_win].vv_git_file_compare_owner ~= nil,
  '旧 cleanup 不能清理新 invisible compare 的 owner token')
vim.api.nvim_win_close(cleanup_invisible_b_ready.ref_win, true)
vim.wait(50, function()
  return vim.api.nvim_win_get_buf(cleanup_invisible_b_ready.source_win) == previous_visible
end)
assert_eq(vim.api.nvim_win_get_buf(cleanup_invisible_b_ready.source_win), previous_visible,
  '关闭 cleanup-reentrant B 恢复 A 之前可见的 buffer')

local invisible_ready
assert(FileCompare.open('HEAD', {
  bufnr = invisible_source,
  root = '/repo',
  on_ready = function(context) invisible_ready = context end,
}))
vim.wait(50, function() return invisible_ready ~= nil end)
assert_eq(vim.api.nvim_win_get_buf(invisible_ready.source_win), invisible_source,
  '不可见 source buffer 被挂载到 owner window')
vim.api.nvim_win_close(invisible_ready.ref_win, true)
vim.wait(50, function() return vim.api.nvim_win_get_buf(invisible_ready.source_win) == previous_visible end)
assert_eq(vim.api.nvim_win_get_buf(invisible_ready.source_win), previous_visible,
  '关闭 compare 恢复精确前一个 buffer')

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
assert(not vim.api.nvim_buf_is_valid(wipe_source), '源 buffer 在测试中被清理')
vim.wait(50, function()
  return not vim.api.nvim_win_is_valid(wipe_ready.ref_win)
      or vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wipe_ready.ref_win)) == ''
end)
if vim.api.nvim_win_is_valid(wipe_ready.ref_win) then
  assert_eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wipe_ready.ref_win)), '',
    '仅剩窗口在源缓冲清理后不再显示 compare UI')
  assert(not vim.wo[wipe_ready.ref_win].diff, '源缓冲清理后仅剩窗口保留 diff 模式')
  assert(vim.w[wipe_ready.ref_win].vv_git_file_compare_owner == nil,
    '源缓冲清理后仅剩窗口释放 compare ownership')
end

Git.show = original_show
UGit.root = original_root
State.clear()
print('PASS: vv-git request scopes 文件比较恢复')
