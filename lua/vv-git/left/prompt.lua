-- Commit message 浮窗：居中 rounded border，支持多行
-- 无 staged 时自动 git add -A（VSCode 的 "Commit All" 行为）
--
-- 按键（浮窗内，normal + insert）：
--   <C-s>     提交
--   <Esc>/q   取消（normal 模式下 q 才生效）

local api = vim.api
local Git = require('vv-git.git')

local M = {}

local cur = nil -- { buf, win }

local function close()
  vim.cmd('stopinsert')
  if not cur then return end
  -- 先快照再清 cur：关窗会同步触发 WinClosed/BufWipeout autocmd 回调，
  -- 其中也会把 cur 置 nil，若沿用 cur.* 取值会在中途变成索引 nil
  local win, buf = cur.win, cur.buf
  cur = nil
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
end

---@param git_root string
---@param commit_all boolean
---@param on_success fun()?
local function submit(git_root, commit_all, on_success)
  vim.cmd('stopinsert')
  if not cur or not cur.buf or not api.nvim_buf_is_valid(cur.buf) then return end
  -- 防重入：Git.commit 是异步的，提交进行中再按 <C-s> 会派生第二个 commit 进程
  if cur.submitting then return end
  local lines = api.nvim_buf_get_lines(cur.buf, 0, -1, false)
  local msg = table.concat(lines, '\n')
  msg = msg:gsub('^%s+', ''):gsub('%s+$', '')
  if msg == '' then
    vim.notify('[vv-git] Commit message cannot be empty', vim.log.levels.WARN)
    return
  end
  cur.submitting = true

  local function do_commit()
    Git.commit(git_root, msg, function(ok, err)
      if not ok then
        if cur then cur.submitting = false end
        vim.notify('[vv-git] Commit failed: ' .. (err or ''), vim.log.levels.ERROR)
        return
      end
      close() -- 清 cur，无需再复位 submitting
      vim.notify('[vv-git] Commit succeeded', vim.log.levels.INFO)
      if on_success then on_success() end
    end)
  end

  if commit_all then
    Git.stage_all(git_root, function(ok, err)
      if not ok then
        if cur then cur.submitting = false end
        vim.notify('[vv-git] git add -A failed: ' .. (err or ''), vim.log.levels.ERROR); return
      end
      do_commit()
    end)
  else
    do_commit()
  end
end

---@param opts { git_root:string, has_staged:boolean, on_success:fun()? }
function M.open(opts)
  close()

  local buf = api.nvim_create_buf(false, true)
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

  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
    footer = ' <C-s> commit  <Esc>/q cancel ',
    footer_pos = 'center',
  })

  -- 给浮窗加一点左侧内边距（padding），让输入文本不至于紧贴边框
  -- 通过设置宽度为 1 的 signcolumn 来挤出左边距
  vim.api.nvim_set_option_value('signcolumn', 'yes:1', { win = win })
  -- 确保 foldcolumn 和 number 都是关闭的，避免多余的空间占用
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = win })
  vim.api.nvim_set_option_value('number', false, { win = win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = win })

  cur = { buf = buf, win = win }

  -- 浮窗被外部关闭（非 close()）时复位 cur，避免残留导致下次校验误判
  api.nvim_create_autocmd({ 'WinClosed', 'BufWipeout' }, {
    buffer = buf,
    once = true,
    callback = function()
      if cur and cur.buf == buf then cur = nil end
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
    submit(opts.git_root, commit_all, opts.on_success)
  end, kopts)
  vim.keymap.set('n', '<Esc>', close, kopts)
  vim.keymap.set('n', 'q', close, kopts)

  vim.cmd('startinsert')
end

function M.close() close() end

return M
