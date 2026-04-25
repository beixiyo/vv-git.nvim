-- 右栏 diff 视图：双栏（a | b）或单栏（只 b）
--
-- 窗口布局模型：
--   [panel] [a_win] [b_win]   ← 正常双栏
--   [panel] [b_win]           ← 新增/删除文件降级单栏
--
-- 复用规则：
--   - 切换文件时优先复用已有 a/b 窗口，只 set_buf（更顺滑）
--   - 双栏 → 单栏切换：关闭 a_win，保留 b_win
--   - 单栏 → 双栏切换：在 b_win 左侧新建 a_win

local api = vim.api
local Git = require('vv-git.git')

local M = {}

-- 依赖注入：由 init.setup 调 M.configure 填入，避免 view → init 的反向 require
---@class VVGitViewHandlers
---@field get_config fun():table
---@field on_close fun()
---@field on_goto_file fun()
---@field on_yank_abs_path fun()
local handlers = {
  get_config       = function() return { fold_unchanged = true } end,
  on_close         = function() end,
  on_goto_file     = function() end,
  on_yank_abs_path = function() end,
}

---@param h VVGitViewHandlers
function M.configure(h)
  handlers = vim.tbl_extend('force', handlers, h or {})
end

---@return boolean
local function fold_unchanged_enabled()
  return handlers.get_config().fold_unchanged ~= false
end

-- a 侧：新增当删除显示 + 整行/词级 = 红系
local WINHL_A = table.concat({
  'DiffAdd:VVGitDiffAddAsDelete',
  'DiffDelete:VVGitDiffDeleteDim',
  'DiffChange:VVGitDiffChangeDelete',
  'DiffText:VVGitDiffTextDelete',
  'Folded:VVGitFold',
}, ',')

-- b 侧：绿系
local WINHL_B = table.concat({
  'DiffAdd:VVGitDiffAdd',
  'DiffDelete:VVGitDiffDeleteDim',
  'DiffChange:VVGitDiffChange',
  'DiffText:VVGitDiffText',
  'Folded:VVGitFold',
}, ',')

local FILETYPE_A = 'vv-git-a'

-- 右侧 diff 窗口的 buffer-local 快捷键（show 时装到 a_buf / b_buf，close 时拆）
-- 回调走注入的 handlers，view 不再反向 require init
local RIGHT_KEYS_SPEC = {
  { 'q',  function() handlers.on_close() end,          'close' },
  { 'gf', function() handlers.on_goto_file() end,      'goto_file' },
  { 'Y',  function() handlers.on_yank_abs_path() end,  'yank_abs_path' },
}

-- fold 键全部包到 buffer-local，用 `:normal!`（带 !）跑 vanilla 实现，绕过用户的
-- 全局 ufo 映射（zR / zM / zr / zm）。仿 diffview.nvim：sindrets/diffview.nvim
-- lua/diffview/actions.lua compat_fold。
--
-- 为什么必须绕开 ufo：
--   ufo.openAllFolds 只跑 `:%foldopen!`，不动 foldlevel。我们 apply_diff_winopts
--   把 foldlevel 锁在 0，:%foldopen! 后 fold "看起来" 开了但 foldlevel 仍为 0；
--   后续任何让 vim 重新评估折叠状态的事件（TTY 重绘、scroll 进入新行、第三方
--   WinScrolled 回调等）都会让所有折叠瞬间塌回去。`:normal! zR` 是 vanilla
--   实现：把 foldlevel 抬到 buffer 最深 fold 层级 → 不会 snap-back。
--
-- 为什么全列而不是只 zR/zM：未列出的 zr/zm/za/zo/zc/... 仍会被 ufo 全局映射拦走，
-- 存在同类 snap-back 风险。一次性全包，免得用户用 `za` 又踩一次坑。
local FOLD_CMDS = {
  'za', 'zA', 'ze', 'zE', 'zo', 'zc', 'zO', 'zC',
  'zr', 'zm', 'zR', 'zM', 'zv', 'zx', 'zX', 'zn', 'zN', 'zi',
}
for _, cmd in ipairs(FOLD_CMDS) do
  RIGHT_KEYS_SPEC[#RIGHT_KEYS_SPEC + 1] = {
    cmd,
    function() pcall(vim.cmd, 'normal! ' .. cmd) end,
    'fold ' .. cmd,
  }
end

---@param buf integer?
local function install_right_keymaps(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  for _, spec in ipairs(RIGHT_KEYS_SPEC) do
    vim.keymap.set('n', spec[1], spec[2], {
      buffer = buf, silent = true, nowait = true,
      desc = 'vv-git: ' .. spec[3],
    })
  end
end

-- 阻止 scratch buffer 进入 Insert mode（只读 + nofile，进入无意义）
---@param buf integer?
local function block_insert_mode(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  for _, key in ipairs({ 'i', 'I', 'a', 'A', 'o', 'O', 's', 'S', 'c', 'C', 'R' }) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true })
  end
end

---@param buf integer?
local function remove_right_keymaps(buf)
  if not buf or not api.nvim_buf_is_valid(buf) then return end
  for _, spec in ipairs(RIGHT_KEYS_SPEC) do
    pcall(vim.keymap.del, 'n', spec[1], { buffer = buf })
  end
end

---@param state table
---@return integer? main_win  panel 右侧的"主工作区"窗口（即 b_win 所在处）
local function main_window(state)
  local mw = state.panel and state.panel.main_win
  if mw and api.nvim_win_is_valid(mw) then return mw end

  -- fallback：在专属 tab 内找除 panel 之外的第一个窗口
  local panel_win = state.panel and state.panel.win
  local tp = state.tabpage
  if tp and api.nvim_tabpage_is_valid(tp) then
    for _, w in ipairs(api.nvim_tabpage_list_wins(tp)) do
      if w ~= panel_win then return w end
    end
  end
  return nil
end

---@param state table
---@return integer? b_win, integer? a_win  a_win 可能为 nil（单栏）
local function ensure_windows(state, want_dual)
  local view = state.view
  local a_ok = view and view.a_win and api.nvim_win_is_valid(view.a_win)
  local b_ok = view and view.b_win and api.nvim_win_is_valid(view.b_win)

  if want_dual then
    if a_ok and b_ok then return view.b_win, view.a_win end
    if b_ok and not a_ok then
      -- 在 b_win 左侧新开 a_win
      api.nvim_set_current_win(view.b_win)
      vim.cmd('leftabove vsplit')
      local a = api.nvim_get_current_win()
      return view.b_win, a
    end
    -- 全新创建：用 main_window 作为 b，然后左侧 vsplit 出 a
    local main = main_window(state)
    if not main then return nil, nil end
    api.nvim_set_current_win(main)
    vim.cmd('leftabove vsplit')
    local a = api.nvim_get_current_win()
    return main, a
  else
    -- 单栏：只要 b，关掉 a
    if a_ok then pcall(api.nvim_win_close, view.a_win, true) end
    if b_ok then return view.b_win, nil end
    local main = main_window(state)
    return main, nil
  end
end

-- 被 diff 视图修改的 win-local 选项：apply 前保存原值到 vim.w[win]，clear 时精确还原
-- 仿 diffview Window.winopt_store（scene/window.lua:L29）。相比之前"还原到全局默认"的写法，
-- 在 _apply_layout 的 narrow→wide 切换中能保留用户对 b_win 的 setlocal 配置
local CHANGED_OPTS = { 'diff', 'scrollbind', 'cursorbind', 'foldmethod', 'foldexpr', 'foldlevel', 'foldenable', 'foldcolumn', 'foldtext', 'winhighlight' }

---@param win integer
local function save_winopts(win)
  if not api.nvim_win_is_valid(win) then return end
  -- 已保存过就不覆盖（切换文件复用 b_win 时不会把"已被 diff 化"的值当 original 记下来）
  if vim.w[win].vv_git_saved then return end
  local saved = {}
  for _, opt in ipairs(CHANGED_OPTS) do
    saved[opt] = api.nvim_get_option_value(opt, { win = win })
  end
  vim.w[win].vv_git_saved = saved
end

---@param win integer
local function restore_winopts(win)
  if not api.nvim_win_is_valid(win) then return end
  local saved = vim.w[win].vv_git_saved
  if not saved then return end
  for opt, val in pairs(saved) do
    pcall(api.nvim_set_option_value, opt, val, { win = win })
  end
  vim.w[win].vv_git_saved = nil
end

---@param win integer
---@param buf integer
---@param winhl string
local function apply_diff_winopts(win, buf, winhl)
  save_winopts(win)
  -- 复用 diff 窗口切 buffer 时必须先关 diff 再 set_buf 再开——nvim 内部 diff 数据
  -- 是按 win 维护的，set_buf 不会触发重建，:diffupdate 也救不回来；
  -- 新 buf 会被沿用旧 hunk 套出"整片替换"假象（folded=0、大量 DiffText）
  if api.nvim_get_option_value('diff', { win = win }) then
    api.nvim_set_option_value('diff', false, { win = win })
  end
  api.nvim_win_set_buf(win, buf)
  api.nvim_set_option_value('diff', true, { win = win })
  api.nvim_set_option_value('scrollbind', true, { win = win })
  api.nvim_set_option_value('cursorbind', true, { win = win })
  -- 锁定 diff 折叠：
  --   foldmethod=diff：treesitter.lua / lsp.lua 会在 FileType/LspAttach 时写 expr，必须覆盖
  --   foldlevel=0：TS autocmd 用 `vim.wo` 落在 current win 上；bufload b_buf 时 current win
  --               恰好是刚 vsplit 出的 a_win（此时 diff=false，守卫失效），于是 foldlevel=99
  --               被写到 a_win，导致"所有折叠默认打开" → 看似没折叠。这里压回 0
  local fold_on = fold_unchanged_enabled()
  if fold_on then
    api.nvim_set_option_value('foldmethod', 'diff', { win = win })
    api.nvim_set_option_value('foldlevel', 0, { win = win })
  end
  api.nvim_set_option_value('foldenable', fold_on, { win = win })
  api.nvim_set_option_value('foldcolumn', fold_on and '1' or '0', { win = win })
  api.nvim_set_option_value('foldtext', "v:lua.require'vv-git.foldtext'.render()", { win = win })
  api.nvim_set_option_value('winhighlight', winhl, { win = win })
end

---@param win integer
local function clear_diff_winopts(win)
  if not api.nvim_win_is_valid(win) then return end
  restore_winopts(win)
end

-- 创建某 rev 的只读 scratch buffer（内容来自 `git show rev:relpath`）。
-- 双侧用：staged 视图的 a/b 都用它（HEAD / :0:）；unstaged 视图的 a 也用它（:0:）
---@param rev string     'HEAD' | ':0' | 任意 git rev 语法
---@param relpath string
---@param root string
---@param cb fun(buf: integer?, err?: string)
local function create_rev_buffer(root, rev, relpath, cb)
  Git.show(root, rev, relpath, function(lines, err)
    if not lines then cb(nil, err); return end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_option_value('buftype', 'nowrite', { buf = buf })
    api.nvim_set_option_value('swapfile', false, { buf = buf })
    api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    api.nvim_set_option_value('modifiable', false, { buf = buf })
    -- 直接按路径匹配 ftplugin 映射，不依赖 buffer name（两次切同文件时 name 抢占会失败）
    -- match 失败时 fallback 到 FILETYPE_A，只触发一次 FileType 事件
    local ft = vim.filetype.match({ filename = relpath, buf = buf }) or FILETYPE_A
    api.nvim_set_option_value('filetype', ft, { buf = buf })
    -- 主动 attach treesitter：用户的 FileType autocmd 会跳过 buftype ~= '' 的 buffer
    pcall(vim.treesitter.start, buf)
    -- 打标：后续 wipe_scratch 靠这个判断"这是 vv-git 自建的 scratch，可以删"，
    -- 不再用 bufhidden == 'wipe' 去旁敲侧击（工作区 buf 若被第三方设成 wipe 会误杀）
    vim.b[buf].vv_git_scratch = true
    cb(buf)
  end)
end

-- 批量 wipe vv-git 自建的 scratch buf；工作区 buf（无标记）保留不动
---@param bufs integer[]?
local function wipe_scratch(bufs)
  for _, b in ipairs(bufs or {}) do
    if b and api.nvim_buf_is_valid(b) and vim.b[b].vv_git_scratch then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
end

-- 获取/加载工作区文件的真实 buffer（unstaged 视图的 b 侧用；可编辑，保存即走 BufWritePost）
-- bufadd 本身就是"存在则复用，不存在则建"的 exact-match 语义，无需先 bufnr 探测。
-- 之前用 vim.fn.bufnr(abspath) 会按 regex 匹配 buffer 名，另一个 buf 名如果恰好
-- 以 abspath 为子串，会被误判为命中。
---@param abspath string
---@return integer buf
local function get_worktree_buffer(abspath)
  local buf = vim.fn.bufadd(abspath)
  if not api.nvim_buf_is_loaded(buf) then
    vim.fn.bufload(buf)
  end
  return buf
end

-- 按 section 路由：
--   staged:   a=HEAD (scratch)   vs  b=:0: (scratch，index 版)   —— 只看增量 staged
--   unstaged: a=:0:  (scratch)   vs  b=worktree (可编辑)          —— 只看未 stage 部分
-- 一侧内容缺失时降级为单栏：
--   staged   + A/??: HEAD 无此文件 → 单栏显示 :0:
--   staged   + D   : :0: 无此文件 → 单栏显示 HEAD（看被删前内容）
--   unstaged + ??  : :0: 无此文件 → 单栏显示工作区
--   unstaged + *D  : 工作区无此文件 → 单栏显示 :0:
-- 任一 git show 失败（二进制/LFS/非 UTF-8）→ 再降一级到工作区单栏
---@param state table
---@param node table  tree node（leaf file）
---@param section 'staged'|'unstaged'
function M.show(state, node, section)
  if node.is_dir then return end
  local xy = node.xy or ''
  if Git.is_conflict(xy) then
    vim.notify('[vv-git] Conflict file v1 is not supported yet; please use git mergetool or other tools', vim.log.levels.WARN)
    return
  end

  -- 异步竞态守卫：每次 show 分配单调递增 req_id。快速切换文件时，嵌套 git show
  -- 回调可能乱序到达，用 req_id 确认当前请求仍是最新才继续。否则 scratch buf
  -- （bufhidden=wipe 因从未挂到窗口而不会触发）需要手动删掉防漏。
  local req_id = (state._show_req_id or 0) + 1
  state._show_req_id = req_id

  local abspath = state.git_root .. '/' .. node.relpath
  -- 切换前的 b_buf：切到不同文件后需从旧 b_buf 拆掉 q/gf，避免它在 bufferline 里被
  -- 其它窗口打开时仍响应（a_buf 是 bufhidden=wipe，自动清理无需额外处理）
  local prev_b_buf = state.view and state.view.b_buf

  -- 公共守卫：回调进来时 req_id 错位或 tab 关了 → 丢弃结果
  -- 只 wipe vv-git 自建的 scratch；工作区 buf 可能别人还在用，不能动
  local function alive(bufs_to_wipe)
    if state._show_req_id == req_id
        and state.tabpage and api.nvim_tabpage_is_valid(state.tabpage) then
      return true
    end
    wipe_scratch(bufs_to_wipe)
    return false
  end

  local function focus_back_to_panel()
    local pw = state.panel and state.panel.win
    if pw and api.nvim_win_is_valid(pw) then
      api.nvim_set_current_win(pw)
    end
  end

  -- 前向声明：render_* 互相调用（降级时）需要先声明才能跨向引用
  local render_single_worktree, render_single_rev
  local render_dual_rev_rev, render_dual_rev_worktree

  -- 单栏挂载：只 b_win + b_buf；不动 diff opts
  local function attach_single(b_buf)
    local b_win = ensure_windows(state, false)
    if not b_win then
      wipe_scratch({ b_buf })
      vim.notify('[vv-git] No main window available', vim.log.levels.ERROR); return
    end
    state.view = {
      mode = 'single', section = section, path = node.relpath,
      b_win = b_win, b_buf = b_buf,
    }
    api.nvim_win_set_buf(b_win, b_buf)
    clear_diff_winopts(b_win)
    if prev_b_buf and prev_b_buf ~= b_buf then remove_right_keymaps(prev_b_buf) end
    install_right_keymaps(b_buf)
    -- scratch buffer（只读 rev 视图）也阻止 Insert mode
    if vim.b[b_buf].vv_git_scratch then block_insert_mode(b_buf) end
    focus_back_to_panel()
  end

  -- 双栏挂载：a_win + b_win，apply diff opts，延迟 zX + syncbind
  local function attach_dual(a_buf, b_buf)
    local b_win, a_win = ensure_windows(state, true)
    if not a_win or not b_win then
      -- 两侧若是 scratch 则一并 wipe；worktree buf 不能动
      wipe_scratch({ a_buf, b_buf })
      vim.notify('[vv-git] Failed to create diff window', vim.log.levels.ERROR); return
    end
    -- 先更新 state.view（在 apply_diff_winopts 触发 BufWinEnter 之前），
    -- 否则自检 autocmd 会把"正在切换的新 buf"误认为 stale 而把视图拆掉
    state.view = {
      mode = 'diff2', section = section, path = node.relpath,
      a_win = a_win, a_buf = a_buf,
      b_win = b_win, b_buf = b_buf,
    }
    apply_diff_winopts(a_win, a_buf, WINHL_A)
    apply_diff_winopts(b_win, b_buf, WINHL_B)
    if prev_b_buf and prev_b_buf ~= b_buf then remove_right_keymaps(prev_b_buf) end
    install_right_keymaps(a_buf)
    install_right_keymaps(b_buf)
    block_insert_mode(a_buf)
    vim.schedule(function()
      pcall(vim.cmd, 'diffupdate')
      -- fold 是 window-local 的懒计算：foldmethod/foldlevel 设了但可见渲染要到
      -- 窗口被 enter 时才重算。nvim_win_call 到各窗口里 zX 强制重算
      for _, w in ipairs({ a_win, b_win }) do
        if api.nvim_win_is_valid(w) then
          api.nvim_win_call(w, function() pcall(vim.cmd, 'normal! zX') end)
        end
      end
      -- scrollbind/cursorbind 不会主动对齐"已有"的视口与光标，只在后续滚动时同步
      -- 首次进入需手动把 a_win 的光标对到 b_win 同一行，再 syncbind 对齐 scroll
      if api.nvim_win_is_valid(a_win) and api.nvim_win_is_valid(b_win) then
        local row = api.nvim_win_get_cursor(b_win)[1]
        local a_max = api.nvim_buf_line_count(a_buf)
        pcall(api.nvim_win_set_cursor, a_win, { math.min(row, a_max), 0 })
        api.nvim_win_call(b_win, function() pcall(vim.cmd, 'syncbind') end)
      end
    end)
    focus_back_to_panel()
  end

  render_single_worktree = function()
    attach_single(get_worktree_buffer(abspath))
  end

  -- 降级路径静默：UI 变成单栏就是用户可见的信号，WARN notify 反而打断工作流
  render_single_rev = function(rev)
    create_rev_buffer(state.git_root, rev, node.relpath, function(b_buf)
      if not alive({ b_buf }) then return end
      if not b_buf then
        render_single_worktree()
        return
      end
      attach_single(b_buf)
    end)
  end

  -- staged 分类：HEAD ↔ :0:，两侧都需要 git show
  -- 两个 git show 互不依赖，并发发起 + barrier 合流，比串行省掉一次 RTT
  -- （staged 文件 j/k 快速切换时每次都能省 5-50ms，取决于仓库/磁盘）
  render_dual_rev_rev = function(a_rev, b_rev)
    local a_buf, b_buf, a_done, b_done = nil, nil, false, false
    local function finalize()
      if not (a_done and b_done) then return end
      if not alive({ a_buf, b_buf }) then return end
      if not a_buf and not b_buf then
        render_single_worktree()
      elseif not a_buf then
        -- a 侧缺 → 只有 b_rev 的 scratch 可用，当 single 展示
        attach_single(b_buf)
      elseif not b_buf then
        wipe_scratch({ a_buf })
        render_single_rev(a_rev)
      else
        attach_dual(a_buf, b_buf)
      end
    end
    create_rev_buffer(state.git_root, a_rev, node.relpath, function(buf)
      a_buf = buf; a_done = true; finalize()
    end)
    create_rev_buffer(state.git_root, b_rev, node.relpath, function(buf)
      b_buf = buf; b_done = true; finalize()
    end)
  end

  -- unstaged 分类：rev ↔ worktree，a 侧 git show
  render_dual_rev_worktree = function(a_rev)
    create_rev_buffer(state.git_root, a_rev, node.relpath, function(a_buf)
      if not alive({ a_buf }) then return end
      if not a_buf then
        render_single_worktree()
        return
      end
      attach_dual(a_buf, get_worktree_buffer(abspath))
    end)
  end

  -- 路由表：按 section + xy 分派
  if section == 'staged' then
    local x = xy:sub(1, 1)
    if x == 'A' or xy == '??' then
      render_single_rev(':0')           -- HEAD 无此文件
    elseif x == 'D' then
      render_single_rev('HEAD')         -- :0 无，显示被删前
    else
      render_dual_rev_rev('HEAD', ':0') -- 正常 staged diff
    end
  else -- unstaged
    if xy == '??' then
      render_single_worktree()           -- :0 无此文件
    elseif xy:sub(2, 2) == 'D' then
      render_single_rev(':0')            -- 工作区已删
    else
      render_dual_rev_worktree(':0')     -- 正常 unstaged diff
    end
  end
end

---@param state table
function M.close(state)
  local view = state.view
  if not view then return end
  if view.a_win and api.nvim_win_is_valid(view.a_win) then
    pcall(api.nvim_win_close, view.a_win, true)
  end
  -- b_win 是工作区文件，不主动关，只清 diff opts
  if view.b_win and api.nvim_win_is_valid(view.b_win) then
    clear_diff_winopts(view.b_win)
  end
  -- 拆 buf-local 快捷键；a_buf 是 bufhidden=wipe 自动清，b_buf 需显式处理
  if view.b_buf then remove_right_keymaps(view.b_buf) end
  state.view = nil
end

-- 仅清 b_win 的 diff winopts，保留 state.view（narrow 模式降级时用，便于 wide 复原）
---@param state table
function M.clear_b_winopts(state)
  local view = state.view
  if view and view.b_win and api.nvim_win_is_valid(view.b_win) then
    clear_diff_winopts(view.b_win)
  end
end

return M
