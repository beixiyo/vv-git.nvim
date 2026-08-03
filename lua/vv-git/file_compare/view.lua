-- FileCompare UI 事务：挂载、资源所有权与清理
local Winopts = require('vv-git.file_compare.winopts')
local Resource = require('vv-git.file_compare.resource')
local Guard = require('vv-git.guard')

local M = {}
local next_owner_id = 0

local function owner_id()
  next_owner_id = next_owner_id + 1
  return 'vv-git-file-compare-' .. next_owner_id
end

local function create_buffer(transaction, lines, filetype, name)
  local buf = vim.api.nvim_create_buf(false, true)
  transaction.ref_buf = buf
  vim.b[buf].vv_git_file_compare_ref_pending = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

local function save_buf_mapping(buf, lhs)
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  local mapping
  vim.api.nvim_buf_call(buf, function()
    local current = vim.fn.maparg(lhs, 'n', false, true)
    if type(current) == 'table' and current.buffer == 1 and next(current) then mapping = current end
  end)
  return mapping
end

local function restore_buf_mapping(buf, lhs, mapping)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
  if mapping then
    vim.api.nvim_buf_call(buf, function() vim.fn.mapset('n', false, mapping) end)
  end
end

local function owns_buf_mapping(buf, lhs, callback)
  local mapping = save_buf_mapping(buf, lhs)
  return mapping ~= nil and mapping.callback == callback
end

local function create_ref_window(transaction)
  local function own(win)
    if transaction.ref_win then return end
    transaction.ref_win = win
    transaction.ref_win_owned = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(function() vim.w[win].vv_git_file_compare_owner = transaction.token end)
    end
  end
  local stop_observing = Guard.observe_open({
    buf = transaction.ref_buf,
    callback = own,
  })
  local ok, ref_win = pcall(vim.api.nvim_open_win, transaction.ref_buf, true, {
    split = 'left',
    win = transaction.source_win,
    noautocmd = true,
  })
  stop_observing()
  if not ok then
    local candidates = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(transaction.source_tab)) do
      local owns_ref_buffer = vim.api.nvim_win_get_buf(win) == transaction.ref_buf
      if win ~= transaction.source_win and owns_ref_buffer then
        candidates[#candidates + 1] = win
      end
    end
    if not transaction.ref_win and #candidates == 1 then own(candidates[1]) end
    error(ref_win, 0)
  end
  vim.b[transaction.ref_buf].vv_git_file_compare_ref_pending = nil
  own(ref_win)
  return ref_win
end

local function has_diff_peer(source_win)
  local tab = vim.api.nvim_win_get_tabpage(source_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= source_win and vim.api.nvim_get_option_value('diff', { win = win }) then
      return true
    end
  end
  return false
end

---@class VVGitFileCompareViewOpts
---@field is_active fun(transaction:table):boolean
---@field release fun(transaction:table)
---@field invoke fun(fn:function?, ...)

---@param opts VVGitFileCompareViewOpts
---@return table
function M.new(opts)
  local self = {}
  local cleanup

  function self.defer_cleanup(transaction, capture_after_enter)
    if transaction.released or transaction.unwind_scheduled then return end
    transaction.unwind_scheduled = true
    transaction.busy = true
    Winopts.freeze(transaction)
    if capture_after_enter then
      Winopts.detach_source_diff(transaction)
      Winopts.capture_close_state(transaction)
    end
    if capture_after_enter then
      local ok, err = pcall(Winopts.capture_on_enter, transaction)
      if not ok then transaction.cleanup_error = tostring(err) end
    end
    transaction.intent.request:dispose()
    vim.schedule(function()
      if transaction.released then return end
      transaction.unwind_scheduled = false
      transaction.busy = false
      cleanup(transaction)
    end)
  end

  cleanup = function(transaction)
    transaction.cleanup_requested = true
    if transaction.busy or transaction.cleaning or transaction.released then return end
    transaction.cleaning = true
    transaction.phase = 'cleaning'

    local ok, cleanup_err = xpcall(function()
      local failed_listener_ids = {}
      for _, id in ipairs(transaction.listener_ids) do
        if id ~= transaction.option_listener_id and not Resource.delete_autocmd(id) then
          failed_listener_ids[#failed_listener_ids + 1] = id
        end
      end

      local source_win = transaction.source_win
      if not transaction.source_desired_winopts then Winopts.freeze(transaction) end
      Winopts.detach_source_diff(transaction)

      local ref_win = transaction.ref_win
      if transaction.ref_win_owned and ref_win and vim.api.nvim_win_is_valid(ref_win) then
        local owner = vim.w[ref_win].vv_git_file_compare_owner
        if owner == nil or owner == transaction.token then
          vim.w[ref_win].vv_git_file_compare_owner = nil
          vim.w[ref_win].vv_statuscol_git_disabled = nil
          transaction.closing_ref = true
          local enter_listener
          local listener_ok, listener_result = pcall(Winopts.capture_on_enter, transaction)
          if not listener_ok then
            transaction.cleanup_error = tostring(listener_result)
          else
            enter_listener = listener_result
          end
          pcall(vim.api.nvim_win_close, ref_win, true)
          transaction.closing_ref = false
          if enter_listener and not Resource.delete_autocmd(enter_listener) then
            failed_listener_ids[#failed_listener_ids + 1] = enter_listener
          end
        end
      end
      transaction.ref_win_owned = false

      if transaction.source_win_owned
          and source_win
          and vim.api.nvim_win_is_valid(source_win)
          and vim.w[source_win].vv_git_file_compare_owner == transaction.token then
        vim.w[source_win].vv_git_file_compare_owner = nil
        vim.w[source_win].vv_statuscol_git_disabled = nil
        transaction.restoring_winopts = true
        Winopts.merge_post_freeze(transaction)
        Winopts.defer_restore(transaction)
        if transaction.replaced_source
            and transaction.previous_buf
            and vim.api.nvim_buf_is_valid(transaction.previous_buf)
            and vim.api.nvim_win_get_buf(source_win) == transaction.source.bufnr then
          pcall(vim.api.nvim_win_set_buf, source_win, transaction.previous_buf)
          local previous_error = Winopts.apply(source_win, transaction.previous_winopts)
          if previous_error and not transaction.cleanup_error then
            transaction.cleanup_error = previous_error
          end
        end
        transaction.restoring_winopts = false
      end
      transaction.source_win_owned = false

      if transaction.option_listener_id then
        if not Resource.delete_autocmd(transaction.option_listener_id) then
          failed_listener_ids[#failed_listener_ids + 1] = transaction.option_listener_id
        end
        transaction.option_listener_id = nil
      end
      transaction.listener_ids = failed_listener_ids
      Resource.retry_delete_autocmds(failed_listener_ids, 3)

      if transaction.source_mapping_owned
          and transaction.source
          and vim.api.nvim_buf_is_valid(transaction.source.bufnr)
          and vim.b[transaction.source.bufnr].vv_git_file_compare_owner == transaction.token then
        vim.b[transaction.source.bufnr].vv_git_file_compare_owner = nil
        for _, lhs in ipairs({ 'q', '<Esc>' }) do
          local expected = transaction.source_mapping_callbacks[lhs] or transaction.close_callback
          local owns_ok, owned = pcall(
            owns_buf_mapping,
            transaction.source.bufnr,
            lhs,
            expected
          )
          if owns_ok and owned then
            pcall(
              restore_buf_mapping,
              transaction.source.bufnr,
              lhs,
              transaction.source_mappings[lhs]
            )
          end
        end
      end
      transaction.source_mapping_owned = false

      if transaction.ref_buf and vim.api.nvim_buf_is_valid(transaction.ref_buf) then
        local ref_buf = transaction.ref_buf
        vim.b[ref_buf].vv_git_file_compare_ref_pending = nil
        for _ = 1, 2 do
          pcall(vim.api.nvim_buf_delete, ref_buf, { force = true })
          if not vim.api.nvim_buf_is_valid(ref_buf) then break end
        end
        if vim.api.nvim_buf_is_valid(ref_buf) then
          if not transaction.cleanup_error then
            transaction.cleanup_error = 'failed to delete ref buffer ' .. ref_buf
          end
          Resource.retry_delete_buffer(ref_buf, 3)
        else
          transaction.ref_buf = nil
        end
      end

      if transaction.opened
          and not transaction.close_notified
          and type(transaction.intent.opts.on_close) == 'function' then
        transaction.close_notified = true
        local context = transaction.context
        vim.defer_fn(function() opts.invoke(transaction.intent.opts.on_close, context) end, 20)
      end
    end, debug.traceback)

    transaction.cleaning = false
    transaction.phase = 'closed'
    opts.release(transaction)
    if not ok then
      vim.notify('[vv-git] File compare cleanup failed: ' .. tostring(cleanup_err), vim.log.levels.ERROR)
    elseif transaction.cleanup_error then
      vim.notify(
        '[vv-git] File compare option cleanup failed: ' .. transaction.cleanup_error,
        vim.log.levels.ERROR
      )
    end
  end

  self.cleanup = cleanup

  ---@return table?
  function self.mount(transaction, ref_lines)
    local request = transaction.intent.request
    local source = transaction.source
    local source_win = transaction.source_win
    if not request:is_current() then return nil end

    transaction.phase = 'mounting'
    transaction.token = owner_id()
    create_buffer(
      transaction,
      ref_lines,
      source.filetype,
      'vv-git://file/' .. transaction.token .. '/' .. transaction.intent.ref .. '/' .. source.relpath
    )
    if not request:is_current() then return nil end

    transaction.previous_winopts = Winopts.save(source_win)
    vim.w[source_win].vv_git_file_compare_owner = transaction.token
    transaction.source_win_owned = true
    if transaction.replaced_source then vim.api.nvim_win_set_buf(source_win, source.bufnr) end
    if not request:is_current() then return nil end

    transaction.source_winopts = Winopts.save(source_win)
    transaction.source_had_diff_peer = has_diff_peer(source_win)
    vim.api.nvim_set_current_win(source_win)
    if not request:is_current() then return nil end

    transaction.ref_win = create_ref_window(transaction)
    if not request:is_current() then return nil end
    for _, win in ipairs({ transaction.ref_win, source_win }) do
      if win == source_win then transaction.source_diff_applied = true end
      vim.api.nvim_win_call(win, function() vim.cmd('noautocmd diffthis') end)
      if win == source_win then
        transaction.source_applied_winopts = Winopts.save(source_win)
        transaction.source_applied_winopt_stamps = Winopts.save_stamps(source_win)
      end
      if not request:is_current() then return nil end
      vim.w[win].vv_statuscol_git_disabled = true
    end

    Winopts.watch(transaction, function() return opts.is_active(transaction) end)
    local function close() request:dispose() end
    transaction.close_callback = close

    for _, buf in ipairs({ transaction.ref_buf, source.bufnr }) do
      if buf == source.bufnr then
        transaction.source_mappings = {
          q = save_buf_mapping(source.bufnr, 'q'),
          ['<Esc>'] = save_buf_mapping(source.bufnr, '<Esc>'),
        }
        vim.b[source.bufnr].vv_git_file_compare_owner = transaction.token
        transaction.source_mapping_owned = true
        transaction.source_mapping_callbacks = {}
      end
      for _, lhs in ipairs({ 'q', '<Esc>' }) do
        vim.keymap.set('n', lhs, close, {
          buffer = buf,
          silent = true,
          nowait = true,
          desc = 'vv-git: close file compare',
        })
        if buf == source.bufnr then
          transaction.source_mapping_callbacks[lhs] = save_buf_mapping(buf, lhs).callback
        end
        if not request:is_current() then return nil end
      end
    end

    transaction.listener_ids[#transaction.listener_ids + 1] = vim.api.nvim_create_autocmd('WinClosed', {
      pattern = { tostring(transaction.ref_win), tostring(source_win) },
      callback = function(args)
        if transaction.released then return end
        Winopts.prepare_close(transaction)
        Winopts.capture_close_state(transaction)
        if transaction.closing_ref then return end
        self.defer_cleanup(transaction, tonumber(args.match) == transaction.ref_win)
      end,
    })
    transaction.listener_ids[#transaction.listener_ids + 1] = vim.api.nvim_create_autocmd({
      'BufHidden', 'BufUnload', 'BufDelete', 'BufWipeout',
    }, {
      buffer = source.bufnr,
      once = true,
      callback = function() vim.schedule(close) end,
    })

    vim.api.nvim_set_current_win(source_win)
    if not request:is_current() then return nil end
    return {
      root = source.root,
      path = source.path,
      ref = transaction.intent.ref,
      bufnr = source.bufnr,
      source_win = source_win,
      ref_win = transaction.ref_win,
    }
  end

  return self
end

return M
