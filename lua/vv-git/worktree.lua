-- worktree.lua — 浮窗列出当前仓库的所有 git worktree，选中即切到该 worktree 看 diff
--
-- 只读取（git worktree list），不做 add/remove；切换由调用方在 on_select 里完成
-- （改 state.git_root + reload）。UI 与状态变更分离，对照 compare.lua / commands.lua

local Git = require('vv-git.git')

local git_icons = require('vv-icons').raw.git
local BRANCH_ICON = (git_icons.git_branches or {}).glyph or ''
local BRANCH_ICON_HL = (git_icons.git_branches or {}).hl or 'VVGitPanelBranch'

local M = {}

local NS = vim.api.nvim_create_namespace('vv-git-worktree')

-- 当前 worktree 的左侧标记（实心点），其余留空白对齐
local CUR_MARK = '●'

---@param wt VVGitWorktree
---@return string label  分支 / detached / bare 的可读名
local function ref_label(wt)
  if wt.branch then return wt.branch end
  if wt.bare then return '(bare)' end
  if wt.detached then
    local short = wt.head and wt.head:sub(1, 7) or '???????'
    return '(detached ' .. short .. ')'
  end
  return '(unknown)'
end

-- 把 home 前缀压成 ~，路径更短更易读
---@param path string
---@return string
local function tilde(path)
  local home = vim.fs.normalize(vim.env.HOME or '')
  if home ~= '' and path:sub(1, #home) == home then
    return '~' .. path:sub(#home + 1)
  end
  return path
end

-- 渲染一行：'<mark> <icon> <ref>   <path>'，返回行文本与各段高亮
---@param wt VVGitWorktree
---@param is_current boolean
---@param ref_w integer  ref 段对齐宽度
---@return string line, table[] segs  segs: { col, len, hl }
local function render_line(wt, is_current, ref_w)
  local segs = {}
  local mark = is_current and CUR_MARK or ' '
  local line = mark .. ' '
  segs[#segs + 1] = { col = 0, len = #mark, hl = is_current and 'VVGitPanelBranch' or 'Comment' }

  if BRANCH_ICON ~= '' then
    segs[#segs + 1] = { col = #line, len = #BRANCH_ICON, hl = BRANCH_ICON_HL }
    line = line .. BRANCH_ICON .. ' '
  end

  local ref = ref_label(wt)
  local ref_hl = wt.detached and 'WarningMsg' or (is_current and 'Title' or 'Normal')
  segs[#segs + 1] = { col = #line, len = #ref, hl = ref_hl }
  line = line .. ref

  -- 用空格把 ref 段补到统一宽度，再接路径
  local pad = ref_w - vim.fn.strdisplaywidth(ref)
  if pad > 0 then line = line .. string.rep(' ', pad) end
  line = line .. '  '

  local p = tilde(wt.path)
  segs[#segs + 1] = { col = #line, len = #p, hl = 'Comment' }
  line = line .. p

  -- 失效 worktree 末尾打标
  if wt.prunable then
    local tag = '  (prunable)'
    segs[#segs + 1] = { col = #line, len = #tag, hl = 'DiagnosticError' }
    line = line .. tag
  elseif wt.locked then
    local tag = '  (locked)'
    segs[#segs + 1] = { col = #line, len = #tag, hl = 'DiagnosticWarn' }
    line = line .. tag
  end

  return line, segs
end

-- 打开浮窗选择器；选中（非当前）worktree 时回调 on_select(wt)
---@param state table
---@param on_select fun(wt: VVGitWorktree)
function M.open_picker(state, on_select)
  if not state.git_root then return end

  Git.worktree_list(state.git_root, function(list, err)
    if not list or #list == 0 then
      vim.notify('[vv-git] ' .. (err or 'No worktrees'), vim.log.levels.WARN)
      return
    end

    -- bare 仓库（bare repo 模式下的 .bare）没有工作树，切过去看不了 diff，从列表剔除
    list = vim.tbl_filter(function(wt) return not wt.bare end, list)
    if #list == 0 then
      vim.notify('[vv-git] No switchable worktree (bare repo only)', vim.log.levels.WARN)
      return
    end

    -- 单 worktree（未建任何 worktree）时无切换意义，直接提示
    if #list == 1 then
      vim.notify('[vv-git] Only the main worktree; no other worktrees found', vim.log.levels.INFO)
      return
    end

    -- ref 段对齐宽度
    local ref_w = 0
    for _, wt in ipairs(list) do
      ref_w = math.max(ref_w, vim.fn.strdisplaywidth(ref_label(wt)))
    end

    local lines, all_segs = {}, {}
    local cur_lnum = 1
    for i, wt in ipairs(list) do
      local is_current = wt.path == state.git_root
      if is_current then cur_lnum = i end
      local line, segs = render_line(wt, is_current, ref_w)
      lines[i] = line
      all_segs[i] = segs
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'vv-git-worktree'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for row, segs in ipairs(all_segs) do
      for _, s in ipairs(segs) do
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, s.col, { end_col = s.col + s.len, hl_group = s.hl })
      end
    end
    vim.bo[buf].modifiable = false

    local width = 0
    for _, l in ipairs(lines) do
      width = math.max(width, vim.fn.strdisplaywidth(l))
    end
    width = math.min(width + 2, vim.o.columns - 8)
    local height = math.min(#lines, math.max(1, vim.o.lines - 8))

    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      style = 'minimal',
      border = 'rounded',
      title = ' Worktrees ',
      title_pos = 'center',
    })
    vim.wo[win].cursorline = true
    vim.wo[win].winhighlight = 'NormalFloat:Normal,FloatBorder:FloatBorder'
    pcall(vim.api.nvim_win_set_cursor, win, { cur_lnum, 0 })

    local function close()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end

    local function choose()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local wt = list[row]
      close()
      if wt then on_select(wt) end
    end

    local function map(lhs, fn)
      vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
    map('<CR>', choose)
    map('l', choose)
    map('<Right>', choose)
    map('q', close)
    map('<Esc>', close)

    -- 失焦自动关闭，避免浮窗残留
    vim.api.nvim_create_autocmd('BufLeave', {
      buffer = buf,
      once = true,
      callback = close,
    })
  end)
end

return M
