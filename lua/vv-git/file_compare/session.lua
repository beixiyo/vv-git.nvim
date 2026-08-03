-- FileCompare 请求、session 编排与 latest-wins 意图队列
local Async = require('vv-utils.async')
local Git = require('vv-git.git')
local UGit = require('vv-utils.git')
local View = require('vv-git.file_compare.view')
local Winopts = require('vv-git.file_compare.winopts')

local M = {}
local compare_scope = Async.scope({ cancel_previous = true })
local active_transaction
local queued_intent
local queued_start_ticket
local start_intent
local schedule_queued_intent

local function invoke(fn, ...)
  if type(fn) ~= 'function' then return end
  local args = { ... }
  vim.schedule(function()
    local ok, err = pcall(fn, unpack(args))
    if not ok then
      vim.notify('[vv-git] callback failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---@param ref string
---@param opts VVGitCompareFileOpts
---@return {root:string, relpath:string, path:string, bufnr:integer, filetype:string}?, string? err
local function resolve_source(ref, opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local path = opts.path
  if not path then
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return nil, 'Invalid source buffer: ' .. tostring(bufnr)
    end
    path = vim.api.nvim_buf_get_name(bufnr)
  end
  if not path or path == '' then return nil, 'Cannot compare an unnamed buffer with ' .. ref end

  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local root = opts.root and UGit.root(opts.root) or UGit.root(vim.fs.dirname(path))
  if not root or path:sub(1, #root + 1) ~= root .. '/' then
    return nil, 'File is not inside a Git repository: ' .. path
  end
  if not vim.api.nvim_buf_is_valid(bufnr)
      or vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) ~= path then
    bufnr = vim.fn.bufadd(path)
    local ok = pcall(vim.fn.bufload, bufnr)
    if not ok or not vim.api.nvim_buf_is_loaded(bufnr) then
      return nil, 'Cannot load file: ' .. path
    end
  end
  return {
    root = root,
    relpath = path:sub(#root + 2),
    path = path,
    bufnr = bufnr,
    filetype = vim.bo[bufnr].filetype,
  }
end

local function release_transaction(transaction)
  if transaction.released then return end
  transaction.released = true
  if active_transaction == transaction then active_transaction = nil end
  schedule_queued_intent()
end

local view = View.new({
  is_active = function(transaction) return active_transaction == transaction end,
  release = release_transaction,
  invoke = invoke,
})

schedule_queued_intent = function()
  if queued_start_ticket or not queued_intent then return end
  local intent = queued_intent
  local ticket = {}
  queued_start_ticket = ticket
  vim.schedule(function()
    if queued_start_ticket ~= ticket then return end
    queued_start_ticket = nil
    if active_transaction then return end
    if queued_intent ~= intent then
      schedule_queued_intent()
      return
    end
    if not intent.request:is_current() then
      queued_intent = nil
      return
    end
    queued_intent = nil
    start_intent(intent)
  end)
end

local function finish_error(transaction, message)
  local publish = transaction.intent.request:finish()
  view.cleanup(transaction)
  if publish then
    vim.notify('[vv-git] ' .. message, vim.log.levels.ERROR)
    invoke(transaction.intent.opts.on_error, message)
  end
end

local function on_show(transaction, ref_lines, err)
  local request = transaction.intent.request
  if transaction.released or active_transaction ~= transaction or not request:is_current() then
    view.cleanup(transaction)
    return
  end
  local source = transaction.source
  local source_win = transaction.source_win
  local owns_pending_source = source
      and source_win
      and vim.api.nvim_win_is_valid(source_win)
      and vim.api.nvim_win_get_tabpage(source_win) == transaction.source_tab
      and vim.api.nvim_get_current_tabpage() == transaction.owner_tab
      and vim.api.nvim_get_current_win() == transaction.owner_win
      and vim.api.nvim_win_get_buf(source_win) == transaction.previous_buf
      and vim.api.nvim_buf_is_valid(source.bufnr)
      and vim.fs.normalize(vim.api.nvim_buf_get_name(source.bufnr)) == source.path
  if not owns_pending_source then
    request:dispose()
    view.cleanup(transaction)
    return
  end
  if not ref_lines then
    finish_error(transaction, 'File compare failed: ' .. (err or 'git show failed'))
    return
  end

  if transaction.pending_winleave_id then
    pcall(vim.api.nvim_del_autocmd, transaction.pending_winleave_id)
    transaction.pending_winleave_id = nil
  end
  transaction.busy = true
  local ok, context_or_err = xpcall(function()
    return view.mount(transaction, ref_lines)
  end, debug.traceback)
  transaction.busy = false
  if not ok then
    finish_error(transaction, 'File compare mount failed: ' .. tostring(context_or_err))
    return
  end
  if transaction.cleanup_requested or not request:is_current() or not context_or_err then
    view.cleanup(transaction)
    return
  end

  transaction.phase = 'ready'
  transaction.opened = true
  transaction.context = context_or_err
  invoke(function()
    if request:is_current()
        and vim.api.nvim_win_is_valid(context_or_err.source_win)
        and vim.api.nvim_win_is_valid(context_or_err.ref_win)
        and type(transaction.intent.opts.on_ready) == 'function' then
      transaction.intent.opts.on_ready(context_or_err)
    end
  end)
end

local function register_pending_listeners(transaction)
  return xpcall(function()
    local source_preleave_listener = vim.api.nvim_create_autocmd('BufLeave', {
      buffer = transaction.source.bufnr,
      callback = function()
        if transaction.released
            or transaction.phase == 'pending'
            or vim.api.nvim_get_current_win() ~= transaction.source_win then
          return
        end
        local ok, desired = pcall(Winopts.desired, transaction, transaction.source_win)
        if ok then transaction.source_leave_candidate = desired end
      end,
    })
    transaction.listener_ids[#transaction.listener_ids + 1] = source_preleave_listener

    local source_leave_listener = vim.api.nvim_create_autocmd('BufWinLeave', {
      buffer = transaction.source.bufnr,
      callback = function()
        if transaction.released
            or transaction.phase == 'pending'
            or transaction.source_owner_changed
            or vim.api.nvim_get_current_win() ~= transaction.source_win then
          return
        end
        transaction.source_desired_winopts = transaction.source_leave_candidate
        transaction.source_owner_changed = true
        view.defer_cleanup(transaction, false)
      end,
    })
    transaction.listener_ids[#transaction.listener_ids + 1] = source_leave_listener

    local source_listener = vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
      callback = function()
        if transaction.released or transaction.source_owner_changed then return end
        local expected_buf = transaction.phase == 'pending'
            and transaction.previous_buf
            or transaction.source.bufnr
        if not vim.api.nvim_win_is_valid(transaction.source_win)
            or vim.api.nvim_win_get_buf(transaction.source_win) ~= expected_buf then
          transaction.source_desired_winopts = transaction.source_leave_candidate
          transaction.source_owner_changed = true
          view.defer_cleanup(transaction, false)
        else
          transaction.source_leave_candidate = nil
        end
      end,
    })
    transaction.listener_ids[#transaction.listener_ids + 1] = source_listener

    transaction.pending_winleave_id = vim.api.nvim_create_autocmd('WinLeave', {
      callback = function()
        if not transaction.released
            and vim.api.nvim_get_current_win() == transaction.owner_win then
          transaction.intent.request:dispose()
        end
      end,
    })
    transaction.listener_ids[#transaction.listener_ids + 1] = transaction.pending_winleave_id
  end, debug.traceback)
end

start_intent = function(intent)
  if not intent.request:is_current() then return true end
  if active_transaction then
    queued_intent = intent
    return true
  end

  local transaction = {
    intent = intent,
    phase = 'resolving',
    busy = true,
    cleaning = false,
    cleanup_requested = false,
    released = false,
    opened = false,
    close_notified = false,
    listener_ids = {},
    source_mapping_owned = false,
    source_win_owned = false,
    ref_win_owned = false,
  }
  active_transaction = transaction
  intent.request:set_disposer(function() view.cleanup(transaction) end)

  local source_error
  local ok, resolve_err = xpcall(function()
    transaction.source, source_error = resolve_source(intent.ref, intent.opts)
    if not transaction.source or not intent.request:is_current() then return end

    local source_win = intent.opts.winid
    if not source_win or not vim.api.nvim_win_is_valid(source_win) then
      local current_win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(current_win) == transaction.source.bufnr then
        source_win = current_win
      else
        source_win = vim.fn.win_findbuf(transaction.source.bufnr)[1] or current_win
      end
    end
    transaction.source_win = source_win
    transaction.source_tab = vim.api.nvim_win_get_tabpage(source_win)
    transaction.owner_win = vim.api.nvim_get_current_win()
    transaction.owner_tab = vim.api.nvim_get_current_tabpage()
    transaction.previous_buf = vim.api.nvim_win_get_buf(source_win)
    transaction.replaced_source = transaction.previous_buf ~= transaction.source.bufnr

    Winopts.apply_restore_ticket(source_win, transaction.source.bufnr, function()
      return active_transaction == transaction and intent.request:is_current()
    end)
    transaction.resolve_owner_valid = vim.api.nvim_win_is_valid(source_win)
        and vim.api.nvim_win_get_tabpage(source_win) == transaction.source_tab
        and vim.api.nvim_win_get_buf(source_win) == transaction.previous_buf
  end, debug.traceback)
  transaction.busy = false

  if transaction.cleanup_requested
      or active_transaction ~= transaction
      or transaction.resolve_owner_valid == false
      or not intent.request:is_current() then
    view.cleanup(transaction)
    return true
  end
  if not ok then
    finish_error(transaction, 'File compare setup failed: ' .. tostring(resolve_err))
    return false
  end
  if not transaction.source then
    finish_error(transaction, source_error or 'Cannot resolve comparison source')
    return false
  end

  transaction.phase = 'pending'
  transaction.busy = true
  local listeners_ok, listeners_err = register_pending_listeners(transaction)
  transaction.busy = false
  if transaction.cleanup_requested or not intent.request:is_current() then
    view.cleanup(transaction)
    return true
  end
  if not listeners_ok then
    finish_error(transaction, 'File compare listener setup failed: ' .. tostring(listeners_err))
    return false
  end

  local producer_ok, producer_err = pcall(
    Git.show,
    transaction.source.root,
    intent.ref,
    transaction.source.relpath,
    function(ref_lines, err) on_show(transaction, ref_lines, err) end
  )
  if not producer_ok then
    finish_error(transaction, 'File compare producer failed: ' .. tostring(producer_err))
    return false
  end
  return true
end

---@param ref string
---@param opts? VVGitCompareFileOpts
---@return boolean started
function M.open(ref, opts)
  opts = opts or {}
  if not ref or ref == '' then
    invoke(opts.on_error, 'ref is required')
    return false
  end
  local request = compare_scope:begin({ key = 'file-compare' })
  local intent = { ref = ref, opts = opts, request = request }
  if not request:is_current() then return true end
  if active_transaction then
    queued_intent = intent
    return true
  end
  queued_intent = nil
  return start_intent(intent)
end

---@class VVGitFileCompareContext
---@field root string
---@field path string
---@field ref string
---@field bufnr integer
---@field source_win integer
---@field ref_win integer

---@class VVGitCompareFileOpts
---@field bufnr? integer 当前侧使用的 buffer，包含未保存内容 @default 当前 buffer
---@field path? string 未提供 bufnr 时当前侧使用的文件 @default 当前 buffer 路径
---@field root? string Git 仓库根；省略时从文件路径探测
---@field winid? integer source 窗口；默认使用当前窗口或第一个显示 bufnr 的窗口
---@field on_ready? fun(context:VVGitFileCompareContext) 两侧 diff 窗口就绪后调用
---@field on_error? fun(message:string) 无法打开比较时调用
---@field on_close? fun(context:VVGitFileCompareContext) 比较分屏关闭后调用

return M
