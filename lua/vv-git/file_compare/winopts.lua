-- FileCompare 窗口选项所有权与延迟恢复
local M = {}
local Resource = require('vv-git.file_compare.resource')

local DIFF_OPTS = {
  'diff',
  'scrollbind',
  'cursorbind',
  'foldmethod',
  'foldexpr',
  'foldlevel',
  'foldenable',
  'foldcolumn',
  'foldtext',
  'wrap',
}

local DIFF_OPT_SET = {}
for _, option in ipairs(DIFF_OPTS) do DIFF_OPT_SET[option] = true end

local restore_tickets = {}
local restore_listener_ids = {}
local restore_listener_state = 'idle'
local restore_listener_reconcile_scheduled = false
local stop_restore_listeners
local ensure_restore_listeners

---@param win integer
---@return table<string, any>
function M.save(win)
  local saved = {}
  for _, option in ipairs(DIFF_OPTS) do
    saved[option] = vim.api.nvim_get_option_value(option, { win = win })
  end
  return saved
end

---@param win integer
---@return table<string, {was_set:boolean, sid:integer, line:integer, chan:integer}>
function M.save_stamps(win)
  local stamps = {}
  for _, option in ipairs(DIFF_OPTS) do
    local info = vim.api.nvim_get_option_info2(option, { win = win })
    stamps[option] = {
      was_set = info.was_set,
      sid = info.last_set_sid,
      line = info.last_set_linenr,
      chan = info.last_set_chan,
    }
  end
  return stamps
end

---@param left {was_set:boolean, sid:integer, line:integer, chan:integer}?
---@param right {was_set:boolean, sid:integer, line:integer, chan:integer}?
---@return boolean
local function same_stamp(left, right)
  return left ~= nil
      and right ~= nil
      and left.was_set == right.was_set
      and left.sid == right.sid
      and left.line == right.line
      and left.chan == right.chan
end

---@param transaction table
---@param win integer
---@return table<string, any>?
function M.desired(transaction, win)
  if not transaction.source_diff_applied or not transaction.source_winopts then return nil end
  local desired = {}
  local dirty = transaction.source_option_dirty or {}
  for option, saved in pairs(transaction.source_winopts) do
    local current_ok, current = pcall(vim.api.nvim_get_option_value, option, { win = win })
    local stamp_ok, current_info = pcall(vim.api.nvim_get_option_info2, option, { win = win })
    local current_stamp = stamp_ok and {
      was_set = current_info.was_set,
      sid = current_info.last_set_sid,
      line = current_info.last_set_linenr,
      chan = current_info.last_set_chan,
    } or nil
    local stamp_changed = not same_stamp(
      current_stamp,
      transaction.source_applied_winopt_stamps
          and transaction.source_applied_winopt_stamps[option]
    )
    if option == 'diff'
        and transaction.automatic_diff_teardown_seen
        and not dirty[option] then
      desired[option] = saved
    elseif dirty[option] and transaction.source_observed_winopts then
      local observed = transaction.source_observed_winopts[option]
      local changed_after_observed = not same_stamp(
        current_stamp,
        transaction.source_observed_winopt_stamps
            and transaction.source_observed_winopt_stamps[option]
      )
      if current_ok and (current ~= observed or changed_after_observed) then
        desired[option] = current
      else
        desired[option] = observed
      end
    elseif current_ok
        and transaction.source_applied_winopts
        and (current ~= transaction.source_applied_winopts[option] or stamp_changed) then
      desired[option] = current
    else
      desired[option] = saved
    end
  end
  return desired
end

---@param win integer
---@param desired table<string, any>?
---@param guard? fun():boolean
---@return string? err
---@return boolean completed
function M.apply(win, desired, guard)
  if not vim.api.nvim_win_is_valid(win) or not desired then return nil, true end
  local first_error
  for _, option in ipairs(DIFF_OPTS) do
    if guard and not guard() then return first_error, false end
    local ok, err = pcall(
      vim.api.nvim_set_option_value,
      option,
      desired[option],
      { win = win, scope = 'local' }
    )
    if not ok and not first_error then first_error = tostring(err) end
    if guard and not guard() then return first_error, false end
  end
  return first_error, true
end

local function has_restore_tickets()
  for _, tickets in pairs(restore_tickets) do
    if next(tickets) then return true end
  end
  return false
end

---@param win integer
---@param buf integer
local function remove_restore_ticket(win, buf)
  local tickets = restore_tickets[win]
  if not tickets then return end
  tickets[buf] = nil
  if not next(tickets) then restore_tickets[win] = nil end
  if not has_restore_tickets() then stop_restore_listeners() end
end

---@param win integer
---@param buf integer
---@param owner_guard? fun():boolean
---@return boolean applied
---@return string? err
function M.apply_restore_ticket(win, buf, owner_guard)
  local tickets = restore_tickets[win]
  local ticket = tickets and tickets[buf]
  if not ticket
      or not vim.api.nvim_win_is_valid(win)
      or not vim.api.nvim_buf_is_valid(buf)
      or vim.api.nvim_win_get_buf(win) ~= buf then
    return false, nil
  end

  local attempt = {}
  ticket.attempt = attempt
  local function owns_target()
    local current_tickets = restore_tickets[win]
    return current_tickets ~= nil
        and current_tickets[buf] == ticket
        and ticket.attempt == attempt
        and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_win_get_buf(win) == buf
        and (not owner_guard or owner_guard())
  end
  local err, completed = M.apply(win, ticket.desired, owns_target)
  if err then
    vim.notify('[vv-git] File compare deferred option cleanup failed: ' .. err, vim.log.levels.ERROR)
  end
  if completed and owns_target() then
    remove_restore_ticket(win, buf)
    return true, err
  end
  if ticket.attempt == attempt then ticket.attempt = nil end
  return false, err
end

local function reconcile_restore_tickets()
  local snapshot = {}
  for win, tickets in pairs(restore_tickets) do
    for buf, ticket in pairs(tickets) do snapshot[#snapshot + 1] = { win, buf, ticket } end
  end
  for _, item in ipairs(snapshot) do
    local win, buf, ticket = unpack(item)
    local tickets = restore_tickets[win]
    if tickets and tickets[buf] == ticket then
      if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
        remove_restore_ticket(win, buf)
      elseif vim.api.nvim_win_get_buf(win) == buf then M.apply_restore_ticket(win, buf) end
    end
  end
  if not has_restore_tickets() then stop_restore_listeners() end
end

local function schedule_restore_listener_reconcile(attempts)
  if restore_listener_reconcile_scheduled or attempts <= 0 then return end
  restore_listener_reconcile_scheduled = true
  vim.schedule(function()
    restore_listener_reconcile_scheduled = false
    if not has_restore_tickets() or restore_listener_state ~= 'idle' then return end
    local err = ensure_restore_listeners()
    if err then schedule_restore_listener_reconcile(attempts - 1) end
  end)
end

ensure_restore_listeners = function()
  if restore_listener_state ~= 'idle' then return nil end
  restore_listener_state = 'creating'
  local created = {}
  local ok, err = xpcall(function()
    created[#created + 1] = vim.api.nvim_create_autocmd('BufWinEnter', {
      callback = function(args)
        M.apply_restore_ticket(vim.api.nvim_get_current_win(), args.buf)
      end,
    })
    created[#created + 1] = vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
      callback = function(args)
        local wins = {}
        for win, tickets in pairs(restore_tickets) do
          if tickets[args.buf] then wins[#wins + 1] = win end
        end
        for _, win in ipairs(wins) do remove_restore_ticket(win, args.buf) end
      end,
    })
    created[#created + 1] = vim.api.nvim_create_autocmd('WinClosed', {
      callback = function(args)
        local win = tonumber(args.match)
        if win then restore_tickets[win] = nil end
        if not has_restore_tickets() then stop_restore_listeners() end
      end,
    })
  end, debug.traceback)
  if not ok then
    restore_listener_state = 'idle'
    local remaining = {}
    for _, id in ipairs(created) do
      if not Resource.delete_autocmd(id) then remaining[#remaining + 1] = id end
    end
    Resource.retry_delete_autocmds(remaining, 3)
    if has_restore_tickets() then schedule_restore_listener_reconcile(3) end
    return tostring(err)
  end
  restore_listener_ids = created
  restore_listener_state = 'active'
  reconcile_restore_tickets()
end

stop_restore_listeners = function()
  if has_restore_tickets() or restore_listener_state ~= 'active' then return end
  local stopping = restore_listener_ids
  restore_listener_ids = {}
  restore_listener_state = 'idle'
  local remaining = {}
  for _, id in ipairs(stopping) do
    if not Resource.delete_autocmd(id) then remaining[#remaining + 1] = id end
  end
  Resource.retry_delete_autocmds(remaining, 3)
end

---@param transaction table
function M.defer_restore(transaction)
  local win = transaction.source_win
  local buf = transaction.source and transaction.source.bufnr
  local desired = transaction.source_desired_winopts
  if not win
      or not vim.api.nvim_win_is_valid(win)
      or not buf
      or not vim.api.nvim_buf_is_valid(buf)
      or not desired then
    return
  end
  restore_tickets[win] = restore_tickets[win] or {}
  local ticket = { desired = desired }
  restore_tickets[win][buf] = ticket
  if vim.api.nvim_win_get_buf(win) == buf then
    local applied, apply_error = M.apply_restore_ticket(win, buf)
    if apply_error then transaction.cleanup_error = apply_error end
    if applied then return end

    local tickets = restore_tickets[win]
    if not tickets or tickets[buf] ~= ticket then return end
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
      remove_restore_ticket(win, buf)
      return
    end
  end
  local listener_error = ensure_restore_listeners()
  if listener_error then
    local tickets = restore_tickets[win]
    if tickets and tickets[buf] == ticket then
      tickets[buf] = nil
      if not next(tickets) then restore_tickets[win] = nil end
    end
    transaction.cleanup_error = 'failed to create deferred restore listeners: ' .. listener_error
  end
end

---@param transaction table
function M.freeze(transaction)
  if transaction.source_desired_winopts then return end
  local win = transaction.source_win
  if not win
      or not vim.api.nvim_win_is_valid(win)
      or not transaction.source
      or vim.api.nvim_win_get_buf(win) ~= transaction.source.bufnr then
    return
  end
  local ok, desired = pcall(M.desired, transaction, win)
  if ok then
    transaction.source_desired_winopts = desired
    local stamps_ok, stamps = pcall(M.save_stamps, win)
    if stamps_ok then transaction.source_freeze_winopt_stamps = stamps end
  end
end

---@param transaction table
function M.detach_source_diff(transaction)
  local isolated_source_diff = transaction.source_winopts
      and transaction.source_winopts.diff == true
      and not transaction.source_had_diff_peer
  if transaction.source_diff_detached
      or not transaction.source_diff_applied
      or not transaction.source_desired_winopts
      or not transaction.source_winopts
      or (transaction.source_winopts.diff ~= false and not isolated_source_diff)
      or not transaction.source
      or not transaction.source_win
      or not vim.api.nvim_win_is_valid(transaction.source_win)
      or vim.api.nvim_win_get_buf(transaction.source_win) ~= transaction.source.bufnr then
    return
  end
  local ok = pcall(vim.api.nvim_win_call, transaction.source_win, function()
    vim.cmd('noautocmd diffoff')
  end)
  if ok then
    transaction.source_diff_detached = true
    local stamps_ok, stamps = pcall(M.save_stamps, transaction.source_win)
    if stamps_ok and transaction.source_freeze_winopt_stamps then
      transaction.source_freeze_winopt_stamps.diff = stamps.diff
      transaction.close_diff_stamp = stamps.diff
    end
    transaction.close_diff_value = false
  end
end

---@param transaction table
function M.merge_after_enter(transaction)
  local win = transaction.source_win
  if not transaction.source_desired_winopts
      or not transaction.source_freeze_winopt_stamps
      or not win
      or not vim.api.nvim_win_is_valid(win)
      or not transaction.source
      or vim.api.nvim_win_get_buf(win) ~= transaction.source.bufnr then
    return
  end
  local values_ok, current = pcall(M.save, win)
  local stamps_ok, stamps = pcall(M.save_stamps, win)
  if not values_ok or not stamps_ok then return end
  for _, option in ipairs(DIFF_OPTS) do
    if not same_stamp(stamps[option], transaction.source_freeze_winopt_stamps[option]) then
      transaction.source_desired_winopts[option] = current[option]
      transaction.source_freeze_winopt_stamps[option] = stamps[option]
    end
  end
end

---@param transaction table
function M.capture_close_state(transaction)
  local win = transaction.source_win
  if not win
      or not vim.api.nvim_win_is_valid(win)
      or not transaction.source
      or vim.api.nvim_win_get_buf(win) ~= transaction.source.bufnr then
    return
  end
  local value_ok, value = pcall(vim.api.nvim_get_option_value, 'diff', { win = win })
  local stamps_ok, stamps = pcall(M.save_stamps, win)
  if value_ok then transaction.close_diff_value = value end
  if stamps_ok then transaction.close_diff_stamp = stamps.diff end
end

---@param transaction table
function M.prepare_close(transaction)
  local win = transaction.source_win
  if not transaction.source_winopts
      or transaction.source_winopts.diff ~= true
      or transaction.source_had_diff_peer
      or not win
      or not vim.api.nvim_win_is_valid(win)
      or not transaction.source
      or vim.api.nvim_win_get_buf(win) ~= transaction.source.bufnr then
    return
  end
  local value_ok, current_diff = pcall(vim.api.nvim_get_option_value, 'diff', { win = win })
  if not value_ok or current_diff ~= false then return end
  local stamps_ok, stamps = pcall(M.save_stamps, win)
  local observed_stamp = transaction.source_observed_winopt_stamps
      and transaction.source_observed_winopt_stamps.diff
  local external_already_won = transaction.source_external_option_dirty
      and transaction.source_external_option_dirty.diff
  if not external_already_won then
    external_already_won = stamps_ok
        and observed_stamp
        and not same_stamp(stamps.diff, observed_stamp)
  end
  if external_already_won then return end
  if transaction.source_option_dirty then transaction.source_option_dirty.diff = nil end
  transaction.automatic_diff_teardown_seen = true
end

---@param transaction table
function M.merge_post_freeze(transaction)
  local win = transaction.source_win
  if not transaction.source_desired_winopts
      or not win
      or not vim.api.nvim_win_is_valid(win)
      or not transaction.source
      or vim.api.nvim_win_get_buf(win) ~= transaction.source.bufnr then
    return
  end
  local values_ok, current = pcall(M.save, win)
  local stamps_ok, stamps = pcall(M.save_stamps, win)
  if not values_ok or not stamps_ok then return end
  transaction.source_freeze_winopt_stamps = transaction.source_freeze_winopt_stamps or {}
  local dirty = transaction.post_freeze_option_dirty or {}
  for _, option in ipairs(DIFF_OPTS) do
    local differs_from_automatic_restore = transaction.source_winopts
        and current[option] ~= transaction.source_winopts[option]
    local supersedes_close_diff = option == 'diff'
        and transaction.close_diff_stamp
        and (current[option] ~= transaction.close_diff_value
          or not same_stamp(stamps[option], transaction.close_diff_stamp))
    if dirty[option]
        or supersedes_close_diff
        or (option ~= 'diff' and differs_from_automatic_restore) then
      transaction.source_desired_winopts[option] = current[option]
      transaction.source_freeze_winopt_stamps[option] = stamps[option]
    end
  end
  transaction.post_freeze_option_dirty = {}
end

---@param transaction table
---@return integer listener_id
function M.capture_on_enter(transaction)
  local id = vim.api.nvim_create_autocmd('WinEnter', {
    once = true,
    callback = function()
      if not transaction.released and vim.api.nvim_get_current_win() == transaction.source_win then
        M.merge_after_enter(transaction)
      end
    end,
  })
  transaction.listener_ids[#transaction.listener_ids + 1] = id
  return id
end

---@param transaction table
---@param is_active fun():boolean
local function schedule_owner_recheck(transaction, is_active)
  local win = transaction.source_win
  if vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == transaction.source.bufnr then
    local ok, candidate = pcall(M.desired, transaction, win)
    if ok then transaction.source_owner_recheck_candidate = candidate end
  end
  if transaction.source_owner_recheck_scheduled then return end
  local ticket = {}
  transaction.source_owner_recheck_scheduled = ticket
  vim.schedule(function()
    if transaction.source_owner_recheck_scheduled ~= ticket then return end
    transaction.source_owner_recheck_scheduled = nil
    if transaction.released or not is_active() or not transaction.intent.request:is_current() then return end
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == transaction.source.bufnr then
      transaction.source_owner_recheck_candidate = nil
      return
    end
    if not transaction.source_desired_winopts then
      transaction.source_desired_winopts = transaction.source_owner_recheck_candidate
    end
    transaction.source_owner_changed = true
    transaction.intent.request:dispose()
  end)
end

---@param transaction table
---@param is_active fun():boolean
---@return integer listener_id
function M.watch(transaction, is_active)
  transaction.source_option_dirty = {}
  transaction.source_external_option_dirty = {}
  transaction.source_observed_winopts = vim.deepcopy(transaction.source_applied_winopts)
  transaction.source_observed_winopt_stamps = vim.deepcopy(
    transaction.source_applied_winopt_stamps
  )
  transaction.source_owner_recheck_candidate = M.desired(transaction, transaction.source_win)
  local id = vim.api.nvim_create_autocmd('OptionSet', {
    pattern = '*',
    callback = function(args)
      if transaction.released or transaction.restoring_winopts or not is_active() then return end

      -- owner 校验独立于 option 事件归属。更早的 non-nested handler 可能已经替换
      -- source buffer，而无关 option 可能是外层唯一可观察到的事件
      schedule_owner_recheck(transaction, is_active)
      local option = args.match
      if DIFF_OPT_SET[option]
          and vim.api.nvim_win_is_valid(transaction.source_win)
          and vim.api.nvim_get_current_win() == transaction.source_win
          and vim.api.nvim_win_get_buf(transaction.source_win) ~= transaction.source.bufnr
          and transaction.source_owner_recheck_candidate then
        -- 更早注册的 handler 可能在本次 non-nested OptionSet 事件中替换 source
        -- buffer。这里只保留可观察到的事件值；采样替换后的 buffer 会误认领无关状态
        transaction.source_owner_recheck_candidate[option] = vim.v.option_new
      end
      if not DIFF_OPT_SET[option]
          or (not transaction.source_desired_winopts
            and not transaction.intent.request:is_current())
          or not vim.api.nvim_win_is_valid(transaction.source_win)
          or vim.api.nvim_win_get_buf(transaction.source_win) ~= transaction.source.bufnr then
        return
      end

      local ok, current = pcall(
        vim.api.nvim_get_option_value,
        option,
        { win = transaction.source_win }
      )
      if not ok or vim.v.option_new ~= current then return end
      local stamp_ok, info = pcall(
        vim.api.nvim_get_option_info2,
        option,
        { win = transaction.source_win }
      )
      local stamp = stamp_ok and {
        was_set = info.was_set,
        sid = info.last_set_sid,
        line = info.last_set_linenr,
        chan = info.last_set_chan,
      } or nil

      if transaction.source_desired_winopts then
        local initial_diff = transaction.source_winopts
            and transaction.source_winopts.diff
        local automatic_owned_teardown = initial_diff == false
            and same_stamp(
              stamp,
              transaction.source_freeze_winopt_stamps
                  and transaction.source_freeze_winopt_stamps[option]
            )
        local automatic_isolated_teardown = initial_diff == true
            and not transaction.source_had_diff_peer
        local automatic_diff_teardown = option == 'diff'
            and current == false
            and (transaction.closing_ref
              or transaction.unwind_scheduled
              or (transaction.ref_win and not vim.api.nvim_win_is_valid(transaction.ref_win)))
            and not transaction.source_diff_detached
            and (automatic_owned_teardown or automatic_isolated_teardown)
            and not transaction.automatic_diff_teardown_seen
        if automatic_diff_teardown then
          transaction.automatic_diff_teardown_seen = true
        end
        if not automatic_diff_teardown then
          transaction.post_freeze_option_dirty = transaction.post_freeze_option_dirty or {}
          transaction.post_freeze_option_dirty[option] = true
        end
        return
      end

      transaction.source_observed_winopts[option] = current
      if stamp_ok then transaction.source_observed_winopt_stamps[option] = stamp end
      transaction.source_option_dirty[option] = true
      transaction.source_external_option_dirty[option] = true
    end,
  })
  transaction.option_listener_id = id
  transaction.listener_ids[#transaction.listener_ids + 1] = id
  return id
end

return M
