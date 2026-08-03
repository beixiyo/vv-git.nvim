-- Commit message 浮窗：居中 rounded border，支持多行
-- 无 staged 时自动 git add -A（VSCode 的 "Commit All" 行为）
--
-- 按键（浮窗内，normal + insert）：
--   <C-s>     提交
--   <Esc>/q   取消（normal 模式下 q 才生效）

local api = vim.api
local Git = require('vv-git.git')

local M = {}

local cur = nil -- { buf, win, on_cancel, cancelled }

---@param owner table
local function notify_cancel(owner)
  if owner.cancelled then return end
  owner.cancelled = true
  if owner.on_cancel then owner.on_cancel() end
end

---@param owner table
---@param cancelled? boolean
local function close_owner(owner, cancelled)
  if owner.closed then return end
  owner.closed = true
  local win, buf = owner.win, owner.buf
  if win and api.nvim_win_is_valid(win) and api.nvim_get_current_win() == win then
    vim.cmd('stopinsert')
  end
  if cur == owner then cur = nil end
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  if cancelled ~= false then notify_cancel(owner) end
end

---@param cancelled? boolean
local function close(cancelled)
  if cur then close_owner(cur, cancelled) end
end

---@param owner table
---@param git_root string
---@param commit_all boolean
---@param on_success fun()?
---@param is_current fun():boolean
local function submit(owner, git_root, commit_all, on_success, is_current)
  vim.cmd('stopinsert')
  if not is_current() then return end
  if cur ~= owner or not owner.buf or not api.nvim_buf_is_valid(owner.buf) then return end
  -- 防重入：Git.commit 是异步的，提交进行中再按 <C-s> 会派生第二个 commit 进程
  if owner.submitting then return end
  -- 快照本次提交所属的 prompt 身份：cur 是模块级单例，提交在途时若又开了新 prompt，
  -- M.open 会装入一张全新的 cur 表。回调里只在 cur == owner（仍是本 prompt）时才
  -- close()/复位 submitting，避免在途回调把刚开的新 prompt 窗口误关掉
  local lines = api.nvim_buf_get_lines(owner.buf, 0, -1, false)
  local msg = table.concat(lines, '\n')
  msg = msg:gsub('^%s+', ''):gsub('%s+$', '')
  if msg == '' then
    vim.notify('[vv-git] Commit message cannot be empty', vim.log.levels.WARN)
    return
  end
  owner.submitting = true

  local function do_commit()
    if not is_current() then return end
    Git.commit(git_root, msg, function(ok, err)
      if not is_current() then return end
      if not ok then
        if cur == owner then cur.submitting = false end
        vim.notify('[vv-git] Commit failed: ' .. (err or ''), vim.log.levels.ERROR)
        return
      end
      if cur == owner then close_owner(owner, false) end
      vim.notify('[vv-git] Commit succeeded', vim.log.levels.INFO)
      if on_success then on_success() end
    end)
  end

  if commit_all then
    Git.stage_all(git_root, function(ok, err)
      if not is_current() then return end
      if not ok then
        if cur == owner then cur.submitting = false end
        vim.notify('[vv-git] git add -A failed: ' .. (err or ''), vim.log.levels.ERROR); return
      end
      do_commit()
    end)
  else
    do_commit()
  end
end

---@param opts { git_root:string, has_staged:boolean, is_current?:fun():boolean, on_success:fun()?, on_cancel?:fun() }
---@return fun() dispose 只关闭本次 prompt 的幂等 disposer
function M.open(opts)
  close()
  local is_current = opts.is_current or function() return true end

  local buf = api.nvim_create_buf(false, true)
  local owner = {
    buf = buf,
    on_cancel = opts.on_cancel,
    cancelled = false,
    closed = false,
  }
  cur = owner
  local function dispose() close_owner(owner) end

  api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  api.nvim_set_option_value('filetype', 'gitcommit', { buf = buf })

  local cols = vim.o.columns
  local lines = vim.o.lines
  local width = math.min(80, math.floor(cols * 0.6))
  local height = 10
  local row = math.floor((lines - height) / 2)
  local col = math.floor((cols - width) / 2)

  local title = opts.has_staged and ' Commit staged changes ' or ' Commit ALL changes '

  local win = api.nvim_open_win(buf, false, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
    footer = ' Commit ^s  Cancel Esc/q ',
    footer_pos = 'center',
  })
  owner.win = win

  if cur ~= owner or not is_current() then
    close_owner(owner)
    return dispose
  end
  api.nvim_set_current_win(win)
  if cur ~= owner or not is_current() then
    close_owner(owner)
    return dispose
  end

  -- 给浮窗加一点左侧内边距（padding），让输入文本不至于紧贴边框
  -- 通过设置宽度为 1 的 signcolumn 来挤出左边距
  vim.api.nvim_set_option_value('signcolumn', 'yes:1', { win = win })
  -- 确保 foldcolumn 和 number 都是关闭的，避免多余的空间占用
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = win })
  vim.api.nvim_set_option_value('number', false, { win = win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = win })

  -- 浮窗被外部关闭（非 close()）时复位 cur，避免残留导致下次校验误判
  api.nvim_create_autocmd({ 'WinClosed', 'BufWipeout' }, {
    buffer = buf,
    once = true,
    callback = function()
      if cur == owner then
        cur = nil
        notify_cancel(owner)
      end
    end,
  })

  if not opts.has_staged then
    -- 使用虚拟文本做占位提示
    local ns = api.nvim_create_namespace('vv-git-commit-hint')
    api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { '  ← No staged files, will auto run git add -A', 'WarningMsg' } },
      virt_text_pos = 'eol',
    })
  end

  local kopts = { buffer = buf, silent = true, nowait = true }
  local commit_all = not opts.has_staged
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    submit(owner, opts.git_root, commit_all, opts.on_success, is_current)
  end, kopts)
  vim.keymap.set('n', '<Esc>', function() close_owner(owner) end, kopts)
  vim.keymap.set('n', 'q', function() close_owner(owner) end, kopts)

  vim.cmd('startinsert')
  if cur ~= owner or not is_current() then close_owner(owner) end
  return dispose
end

function M.close() close() end

return M
