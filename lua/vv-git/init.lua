-- vv-git.nvim — VSCode 风 git diff 双栏视图（本地 vendor）
--
-- 架构（仿 diffview）：在专属 tabpage 里做 diff，避免与用户当前 tab 的其它窗口共享 diff-group
--   - M.open()   → `tab split` 创建新 tab，在其中放 panel + main(b_win)
--   - M.close()  → `tabclose` 整个 tab，回跳 prev_tab
--   - state 是全局单例（同时只能有一个 vv-git tab）
--
-- 公开 API：require('vv-git').{ setup | open | close | toggle | refresh }
-- 用户命令：:VVGit / :VVGitClose / :VVGitToggle / :VVGitRefresh

local State = require('vv-git.state')
local HL = require('vv-git.hl')
local Panel = require('vv-git.left.panel')
local Git = require('vv-git.git')
local LeftRender = require('vv-git.left.render')
local RightView = require('vv-git.right.view')
local Actions = require('vv-git.left.actions')
local Prompt = require('vv-git.left.prompt')
local Help = require('vv-git.help')
local Loader = require('vv-git.loader')
local Autocmds = require('vv-git.autocmds')
local Guard = require('vv-git.guard')
local Editor = require('vv-utils.editor')

local M = {}

---@class VVGitConfig
---@field width integer
---@field single_col_threshold integer  -- 终端列数 < 此值时 diff 视图降级为单栏（仅 b 侧，无 inline diff），≥ 此值时正常 dual diff；resize 时自动迁移
---@field keymap_toggle_panel string|false  -- 全局切换左栏的 normal 映射；false 禁用
---@field fold_unchanged boolean  -- diff 视图默认折叠未改动代码
---@field diff_fill string  -- diff 空行填充符（Vim 默认 '-'），映射到 fillchars 的 diff:X
---@field preview boolean  -- panel 中光标移动到文件行时自动刷新右侧 diff，无需手动 <CR>/o/l
---@field inline_diff_max_lines integer  -- 单栏模式下 inline diff 最大支持行数，超过则跳过高亮（避免 vim.diff 大文件卡）
local defaults = {
  width = 30,
  single_col_threshold = 120,
  keymap_toggle_panel = '<leader>b',
  fold_unchanged = true,
  diff_fill = ' ',
  preview = true,
  inline_diff_max_lines = 10000,
}

M._config = vim.deepcopy(defaults)

---@param opts VVGitConfig?
function M.setup(opts)
  M._config = vim.tbl_deep_extend('force', defaults, opts or {})

  HL.setup()

  -- 向 RightView 注入依赖，解除 view → init 的反向 require
  RightView.configure({
    get_config        = function() return M._config end,
    on_close          = function() M.close() end,
    on_goto_file      = function() M._goto_file() end,
    on_yank_abs_path  = function() M._yank_abs_path() end,
  })

  local function ucmd(name, fn, cfg)
    vim.api.nvim_create_user_command(name, fn, cfg or {})
  end
  ucmd('VVGit',             function() M.open() end)
  ucmd('VVGitClose',        function() M.close() end)
  ucmd('VVGitToggle',       function() M.toggle() end)
  ucmd('VVGitTogglePanel',  function() M.toggle_panel() end)
  ucmd('VVGitRefresh',      function() M.refresh() end)

  if M._config.keymap_toggle_panel then
    vim.keymap.set('n', M._config.keymap_toggle_panel, function() M.toggle_panel() end, {
      silent = true, desc = 'vv-git: toggle panel',
    })
  end

  -- diffopt 细粒度匹配：没 linematch 时整块变化会被当成全量替换
  -- 用户别处若已设 linematch:N，再 append 'linematch:60' 会产生重复条目
  -- （观察到过 `...linematch:40,linematch:60` 的实际日志）。nvim 对重复
  -- linematch 的生效顺序不稳定，先全剔除再写入保证只有一份
  pcall(function()
    local parts = vim.split(vim.o.diffopt, ',', { plain = true })
    local kept = {}
    for _, p in ipairs(parts) do
      if p ~= '' and not p:match('^linematch:') then
        kept[#kept + 1] = p
      end
    end
    kept[#kept + 1] = 'linematch:60'
    vim.o.diffopt = table.concat(kept, ',')
  end)
  -- 横向滚动同步（默认 scrollopt=ver,jump 只同步垂直 + jump）
  pcall(function() vim.opt.scrollopt:append('hor') end)
  -- diff 空行填充符（Vim 默认 '-'）；fillchars 最后匹配胜出，append 等价于覆盖
  pcall(function() vim.opt.fillchars:append({ diff = M._config.diff_fill or ' ' }) end)

  Autocmds.setup({
    on_refresh          = function() M.refresh() end,
    on_apply_layout     = function() M._apply_layout() end,
    on_ensure_invariant = function() M._ensure_invariant() end,
  })
end

---@return string? git_root
local function detect_git_root()
  local cwd = vim.fn.getcwd()
  local result = vim.fn.systemlist({ 'git', '-C', cwd, 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 or not result[1] or result[1] == '' then
    return nil
  end
  return vim.fs.normalize(result[1])
end

-- 预转 <C-e>/<C-y> 的 termcode，给 scroll_diff 走 `normal!` 用
local CE_KEY = vim.api.nvim_replace_termcodes('<C-e>', true, false, true)
local CY_KEY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

-- panel 上按 <C-e>/<C-y> 时把滚动委派给右侧 b_win（scrollbind=true，a_win 会跟随同步）
-- 步长 5 行，和用户跨 nvim/fzf 的滚动习惯一致
--
-- 必须走真实 set_current_win 切焦点，不能用 nvim_win_call：
--   - nvim_win_call 只改"当前 win 指针"但不触发 WinEnter/Leave，也不进 Vim 的滚动事件队列
--   - diff-mode 两侧 fold 分布不同（a/b 因新增/删除行数不等，unchanged 段长度也不同），
--     syncbind 按固定 offset 拉齐会错位；只有原生 <C-e>/<C-y> 知道按 hunk 对应关系同步
-- 切完再切回 panel，保持用户焦点
---@param keys string  已 termcode 化的 <C-e>/<C-y>
local function scroll_diff(keys)
  if not State.has() then return end
  local target = State.get().view and State.get().view.b_win
  if not target or not vim.api.nvim_win_is_valid(target) then return end
  local prev = vim.api.nvim_get_current_win()
  if prev == target then
    pcall(vim.cmd, 'normal! 5' .. keys)
    return
  end
  pcall(vim.api.nvim_set_current_win, target)
  pcall(vim.cmd, 'normal! 5' .. keys)
  if vim.api.nvim_win_is_valid(prev) then
    pcall(vim.api.nvim_set_current_win, prev)
  end
end

---@param state table
local function install_keymaps(state)
  local buf = state.panel.buf
  local function map(lhs, fn, action)
    vim.keymap.set('n', lhs, fn, {
      buffer = buf, silent = true, nowait = true,
      desc = 'vv-git: ' .. action,
    })
  end
  map('q',             function() M.close() end,                   '__close')
  map('R',             function() M.refresh() end,                 'refresh')
  map('<CR>',          function() M._activate() end,               'open')
  map('o',             function() M._activate() end,               'open')
  map('l',             function() M._activate(true) end,           'expand')
  map('<2-LeftMouse>', function() M._activate() end,               'open')
  map('gf',            function() M._goto_file() end,              'goto_file')
  map('Y',             function() M._yank_abs_path() end,           'yank_abs_path')
  map('<Tab>',         function() M._toggle_fold() end,            'toggle_fold')
  map('h',             function() M._collapse() end,               'close_node')
  map('s',             function() M._action('toggle_stage') end,   'toggle_stage')
  map('X',             function() M._action('discard') end,        'discard')
  map('c',             function() M._commit() end,                 'commit')
  map('p',             function() M._push() end,                   'push')
  map('P',             function() M._pull() end,                   'pull')
  map('<C-e>',         function() scroll_diff(CE_KEY) end,         'scroll_diff_down')
  map('<C-y>',         function() scroll_diff(CY_KEY) end,         'scroll_diff_up')
  map('g?',            function() Help.open(state) end,            'help')

  -- 阻止 Insert mode：buftype=nofile + modifiable=false 下进入 Insert 无意义
  -- 排除已映射为功能键的 o/s/c/R，只屏蔽纯 Insert 入口
  for _, key in ipairs({ 'i', 'I', 'a', 'A', 'O', 'S', 'C' }) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true })
  end

  -- preview 模式：光标落到文件行自动刷新右侧 diff；停在 header/目录 上不动（保留上一次预览）
  -- buffer-local：panel_buf 被 wipe 时 autocmd 自动销毁，无需手动清理
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = State.guarded(function(s) M._preview() end),
    desc = 'vv-git: preview on cursor move',
  })
end

-- 光标行对应的 id（section_header 或 { section, node }）
---@param state table
---@return table?
local function id_under_cursor(state)
  if not state.panel or not state.panel.win then return nil end
  if not vim.api.nvim_win_is_valid(state.panel.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.panel.win)[1]
  return state.panel.id_by_line and state.panel.id_by_line[lnum]
end

function M.open()
  -- 已有 vv-git tab → 直接跳过去
  if State.has() then
    local s = State.get()
    if s.tabpage and vim.api.nvim_tabpage_is_valid(s.tabpage) then
      vim.api.nvim_set_current_tabpage(s.tabpage)
      if s.panel and s.panel.win and vim.api.nvim_win_is_valid(s.panel.win) then
        vim.api.nvim_set_current_win(s.panel.win)
      end
      return
    end
    State.clear()
  end

  -- 不再因为窄终端拒绝打开：宽度不够时 _activate / _preview 会自动走 single 路径，
  -- diff 视图降级为单栏（仅 b 侧）；用户拉宽后下次 j/k 切文件或 resize 自动升回 dual

  local root = detect_git_root()
  if not root then
    vim.notify('[vv-git] Not a git repository', vim.log.levels.WARN)
    return
  end

  local prev_tab = vim.api.nvim_get_current_tabpage()

  -- 开专属 tab（`tab split` 复制当前 buffer 进新 tab 作为起始窗口）
  vim.cmd('tab split')
  local tabpage = vim.api.nvim_get_current_tabpage()
  local main_win = vim.api.nvim_get_current_win()

  -- 在左侧 vsplit 出 panel
  local panel_buf = Panel.create_buf()
  Panel.open_split(panel_buf, { width = M._config.width })
  local panel_win = vim.api.nvim_get_current_win()

  local state = State.get()
  state.tabpage = tabpage
  state.prev_tab = prev_tab
  state.git_root = root
  state.panel = {
    buf = panel_buf,
    win = panel_win,
    main_win = main_win,
  }

  install_keymaps(state)

  -- 劫持 nvim_open_win，拦第三方浮窗从 diff 窗口继承 diff=true（见 guard.lua 注释）
  -- 放在 state.tabpage 已就绪之后；TabClosed 会 uninstall
  Guard.install()

  Loader.reload_index(state)
  M._apply_layout()
end

-- 关闭 vv-git：只触发 tabclose；状态清理统一由 TabClosed autocmd 负责（单一来源）
-- 这样 :wq / :q / <C-w>q / <leader>b 等所有退出路径都能被回收，不再产生孤儿 tab
M.close = State.guarded(function(state)
  local tp = state.tabpage
  local prev_tab = state.prev_tab

  -- 兜底：vv-git tab 是唯一 tab → 关闭会退出 nvim
  if tp and vim.api.nvim_tabpage_is_valid(tp) and #vim.api.nvim_list_tabpages() == 1 then
    vim.notify('[vv-git] This is the only tab. Closing it will exit nvim. Please open a new tab first.', vim.log.levels.WARN)
    return
  end

  if tp and vim.api.nvim_tabpage_is_valid(tp) then
    pcall(function()
      local pagenr = vim.api.nvim_tabpage_get_number(tp)
      vim.cmd('tabclose ' .. pagenr)
    end)
    if prev_tab and vim.api.nvim_tabpage_is_valid(prev_tab) then
      pcall(vim.api.nvim_set_current_tabpage, prev_tab)
    end
  else
    -- stale state（TabClosed 没捕到）→ 手动兜底清理
    pcall(RightView.close, state)
    State.clear()
  end
end)

-- vv-git tab 的存活契约：panel 可见 OR 右侧 diff 视图活跃。
-- 二者都失效 → tab 是僵尸，调度 M.close 回收。
-- 被 autocmds（WinClosed / BufWinEnter stale）调用
---@return nil
M._ensure_invariant = State.guarded(function(state)
  local panel_visible = state.panel
    and state.panel.win
    and vim.api.nvim_win_is_valid(state.panel.win)
  local view_active = state.view ~= nil
  if not (panel_visible or view_active) then
    vim.schedule(function() M.close() end)
  end
end)

function M.toggle()
  if State.has() then
    local s = State.get()
    if s.tabpage and vim.api.nvim_tabpage_is_valid(s.tabpage) then
      M.close()
      return
    end
  end
  M.open()
end

-- 在 vv-git 专属 tab 内切换左栏可见性（<leader>b）。_panel_hidden 供未来的
-- 布局逻辑判断"用户是否显式隐藏过 panel"
M.toggle_panel = State.guarded(function(state)
  if state.tabpage ~= vim.api.nvim_get_current_tabpage() then return end
  if not state.panel or not state.panel.buf then return end

  local win = state.panel.win
  local visible = win and vim.api.nvim_win_is_valid(win)

  if visible then
    -- 先把焦点挪到主窗口，再关 panel，避免关闭 panel 时焦点落到 a_win
    local main = state.panel.main_win
    if main and vim.api.nvim_win_is_valid(main) then
      pcall(vim.api.nvim_set_current_win, main)
    end
    Panel.close_win(win)
    state.panel.win = nil
    state._panel_hidden = true
  else
    Panel.open_split(state.panel.buf, { width = M._config.width })
    state.panel.win = vim.api.nvim_get_current_win()
    state._panel_hidden = false
    LeftRender.render(state)
  end
end)

M.refresh = State.guarded(function(state)
  if not state.panel or not state.git_root then return end
  Loader.reload_index(state)
end)

M._toggle_fold = State.guarded(function(state)
  local id = id_under_cursor(state)
  if not id or not id.node or not id.node.is_dir then return end
  -- 三值 toggle：nil(展开) ↔ true(折叠)；`or nil` 把 false 归一为 nil，保持表稀疏
  state.folds[id.node.relpath] = not state.folds[id.node.relpath] or nil
  state.cur_path = id.node.relpath
  LeftRender.render(state)
end)

-- h：折叠当前目录；在文件上时跳父目录并折叠
M._collapse = State.guarded(function(state)
  local id = id_under_cursor(state)
  if not id or not id.node then return end
  local target_path
  if id.node.is_dir and not state.folds[id.node.relpath] then
    target_path = id.node.relpath
  else
    target_path = vim.fs.dirname(id.node.relpath)
    if target_path == '.' or target_path == '' then return end
  end
  state.folds[target_path] = true
  state.cur_path = target_path
  LeftRender.render(state)
end)

-- 当前终端宽度是否容不下 dual diff（panel + a_win + b_win）→ 触发单栏降级
---@return boolean
local function is_narrow() return vim.o.columns < M._config.single_col_threshold end

-- preview：j/k 光标移动触发。只处理文件行；header/目录行保留上一次预览不动
-- 复用 RightView.show 内置的 req_id 竞态守卫 + 相同 path/section 短路，快速 j/k 不会抖
M._preview = State.guarded(function(state)
  if not M._config.preview then return end
  if not state.panel or state.panel.win ~= vim.api.nvim_get_current_win() then return end
  local id = id_under_cursor(state)
  if not id or id.section_header then return end
  local node = id.node
  if not node or node.is_dir then return end
  local view = state.view
  if view and view.path == node.relpath and view.section == id.section
      and view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
    return
  end
  state.cur_path = node.relpath
  RightView.show(state, node, id.section, is_narrow())
end)

-- <CR>/o/l：文件 → 打开 diff；目录 → 折叠切换；section header → 忽略
-- expand_only=true（l 专用）：目录已展开时不折叠，折叠交给 h
M._activate = State.guarded(function(state, expand_only)
  local id = id_under_cursor(state)
  if not id then return end
  if id.section_header then return end
  local node = id.node
  if not node then return end
  if node.is_dir then
    -- expand_only 且已展开 → no-op；其余情况正常 toggle
    if not expand_only or state.folds[node.relpath] then
      M._toggle_fold()
    end
    return
  end
  state.cur_path = node.relpath
  -- 同一文件同一 section → 短路，避免 a_buf 重建导致语法丢失
  local view = state.view
  if view and view.path == node.relpath and view.section == id.section
      and view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
    return
  end
  RightView.show(state, node, id.section, is_narrow())
end)

-- VimResized → 评估当前 view 是否需要在 dual ↔ single 之间迁移
--
-- 不变式安全：panel 始终保留，`ensure_invariant` 的「panel OR view」条件总成立——
-- 不会出现前任那次「连 panel 也藏」导致 WinClosed → ensure_invariant 误杀 tab 的失败链路
--
-- 去抖：拖拽 resize 过程中 VimResized 一秒能触发十几次。「want vs current 一致」短路
-- 已能跳过同状态重 show，但「在阈值附近来回拖拽」会每次都跨阈值重 show（每次伴随
-- git show 子进程 + vim.diff，5-50ms）。挂个 50ms 定时器把连续事件折成一次
--
-- 短路条件：
--   - 没有 view：仅有 panel，无需调整
--   - intrinsic_single：A/D/?? 这类文件本身就该单栏，宽度变化不影响
--   - want vs current 一致：resize 抖动时 mode 已经匹配，不重 show
local function do_apply_layout(state)
  if not state.git_root then return end
  local view = state.view
  if not view or not view.node then return end
  if view.intrinsic_single then return end

  local want_single = is_narrow()
  local is_now_single = (view.mode == 'single')
  if want_single == is_now_single then return end

  -- 复用 RightView.show 的完整路由：传 force_single 后，路由表自动选 single 或 dual
  RightView.show(state, view.node, view.section, want_single)
end

M._apply_layout = State.guarded(function(state)
  if state._resize_timer then pcall(state._resize_timer.close, state._resize_timer) end
  state._resize_timer = vim.uv.new_timer()
  if not state._resize_timer then do_apply_layout(state); return end
  state._resize_timer:start(50, 0, vim.schedule_wrap(function()
    if state._resize_timer then pcall(state._resize_timer.close, state._resize_timer) end
    state._resize_timer = nil
    if State.has() then do_apply_layout(State.get()) end
  end))
end)

M._commit = State.guarded(function(state)
  if not state.git_root then return end
  Git.has_staged(state.git_root, function(has)
    local function open_prompt()
      Prompt.open({
        git_root = state.git_root,
        has_staged = has,
        on_success = function() M.refresh() end,
      })
    end
    if has then
      open_prompt()
    else
      vim.ui.select({ 'Commit ALL working tree', 'Cancel' }, {
        prompt = 'No staged changes. Commit all working tree changes instead?',
      }, function(choice)
        if choice == 'Commit ALL working tree' then open_prompt() end
      end)
    end
  end)
end)

---@param action 'push'|'pull'
local git_net = State.guarded(function(state, action)
  if not state.git_root then return end
  local fn = Git[action]
  vim.notify('[vv-git] ' .. action .. '...', vim.log.levels.INFO)
  fn(state.git_root, function(ok, out)
    local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
    local prefix = ok and ('[vv-git] ' .. action .. ' succeeded') or ('[vv-git] ' .. action .. ' failed')
    vim.notify(prefix .. (out and ('\n' .. out) or ''), level)
    if ok and action == 'pull' then M.refresh() end
  end)
end)

function M._push() git_net('push') end
function M._pull() git_net('pull') end

-- gf：脱离 diff 视图，在原 tab 普通打开该文件
-- panel 上：读光标下节点
-- 右侧 a_win/b_win 上：用 view.path + b_win 光标行（cursorbind 保证 a/b 光标对应同一真实行）
M._goto_file = State.guarded(function(state)
  local cur_win = vim.api.nvim_get_current_win()
  local view = state.view
  local abspath, row = nil, nil

  if view and view.path
      and (cur_win == view.a_win or cur_win == view.b_win) then
    abspath = state.git_root .. '/' .. view.path
    if view.b_win and vim.api.nvim_win_is_valid(view.b_win) then
      row = vim.api.nvim_win_get_cursor(view.b_win)[1]
    end
  else
    local id = id_under_cursor(state)
    if not id or not id.node or id.node.is_dir then return end
    abspath = state.git_root .. '/' .. id.node.relpath
  end

  M.close()   -- 会关整个 vv-git tab，并跳回 prev_tab
  vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
  if row then
    pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
    pcall(vim.cmd, 'normal! zz')
  end
end)

-- Y：复制绝对路径到 + 寄存器
-- panel 上：读光标下节点（含目录）
-- 右侧 a_win/b_win 上：用 view.path
M._yank_abs_path = State.guarded(function(state)
  if not state.git_root then return end
  local cur_win = vim.api.nvim_get_current_win()
  local view = state.view
  local relpath

  if view and view.path
      and (cur_win == view.a_win or cur_win == view.b_win) then
    relpath = view.path
  else
    local id = id_under_cursor(state)
    if not id or not id.node then return end
    relpath = id.node.relpath
  end

  local abs = vim.fs.normalize(state.git_root .. '/' .. relpath)
  Editor.copy_path({ path = abs, title = 'vv-git' })
end)

---@param name 'toggle_stage'|'discard'
M._action = State.guarded(function(state, name)
  local id = id_under_cursor(state)
  if not id then return end
  if id.node then state.cur_path = id.node.relpath end
  -- 动作后光标策略：render 优先在原 section 向下找下一个节点，
  -- 避免 stage 后跟着文件跳到另一分类打断工作流
  if id.node and id.section and state.panel and state.panel.win
      and vim.api.nvim_win_is_valid(state.panel.win) then
    local lnum = vim.api.nvim_win_get_cursor(state.panel.win)[1]
    state._action_hint = { section = id.section, lnum = lnum }
  end
  local fn = Actions[name]
  if fn then fn(state, id) end
end)

---@return table
function M.config() return M._config end

return M
