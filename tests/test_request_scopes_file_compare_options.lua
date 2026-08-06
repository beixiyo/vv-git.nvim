-- vv-git FileCompare mapping 与 option 所有权回归

local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  .. '/helpers/request_scope.lua')
local assert_eq = H.assert_eq
local noop = H.noop
local FileCompare = require('vv-git.file_compare')
local Git = require('vv-git.git')
local Guard = require('vv-git.guard')
local State = require('vv-git.state')
local UGit = require('vv-utils.git')
local state = State.create()
local source_buf = H.create_file_compare_fixture()
local original_show = Git.show
local original_root = UGit.root
local partial_saved_notify = vim.notify
Git.show = function(_, _, _, callback) callback({ 'content' }) end
UGit.root = function() return '/repo' end

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

Git.show = original_show
UGit.root = original_root
State.clear()
print('vv-git request scopes file compare options: PASS')
