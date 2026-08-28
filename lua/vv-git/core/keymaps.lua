-- panel buffer-local 快捷键 + 辅助函数（scroll_diff / navigate / id_under_cursor）

local State = require('vv-git.state')
local RightView = require('vv-git.right.view')
local LeftRender = require('vv-git.left.render')
local Help = require('vv-git.help')
local Scroll = require('vv-utils.scroll')
local Navigation = require('vv-git.core.navigation')

local L = {}

-- 选滚动锚点：a/b 两个 diff 窗口 scrollbind 联动，驱动哪个都会带动另一个，但驱动方自身
-- 必须有足够内容才能滚到底。固定用 b_win（新/after 侧）在大批量「删除」时会失灵——此时
-- b_win 内容很少（filler 占位不可作为 <C-e> 的滚动余量），而 a_win（旧/before 侧）才装着
-- 全部被删的行。故取**缓冲区行数最多**的那个 diff 窗口当锚点，保证总能覆盖全文滚动
---@param view table
---@return integer? win
local function pick_scroll_anchor(view)
  if not view then return nil end
  local best, best_n
  for _, w in ipairs({ view.b_win, view.a_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(w))
      if not best or n > best_n then best, best_n = w, n end
    end
  end
  return best
end

---@param direction 1 | -1
local function scroll_diff(direction)
  if not State.has() then return end
  local target = pick_scroll_anchor(State.get().view)
  if not target or not vim.api.nvim_win_is_valid(target) then return end
  Scroll.window(target, direction * 5)
end

-- 在左侧面板里驱动右侧 diff 窗口跳转到下/上一个 chunk
-- `]c` / `[c` 是 Neovim 原生 diff-mode 动作，只在 `diff=true` 的窗口里有意义；面板 buffer
-- 不是 diff 窗口，直接映射无效。这里用 nvim_win_call 把动作放到 diff 锚点窗口的上下文里执行
-- （a/b 两窗 cursorbind 联动，驱动其一即可），光标焦点仍留在面板，与 scroll_diff 一致
---@param direction ']' | '['
local function jump_chunk(direction)
  if not State.has() then return end
  local target = pick_scroll_anchor(State.get().view)
  if not target or not vim.api.nvim_win_is_valid(target) then return end
  Scroll.with_view_animation(target, function()
    -- ]czz / [czz：跳到 chunk 后把落点居中，和「打开文件自动跳首个变更 + zz」一致
    -- zz 在锚点窗执行，scrollbind 会带动另一侧同步居中
    pcall(vim.cmd, 'normal! ' .. direction .. 'czz')
  end)
end

---@param state table
---@param direction 'j'|'k'
local function navigate(state, direction)
  if not state.panel or not state.panel.win then return end
  if not vim.api.nvim_win_is_valid(state.panel.win) then return end
  local current = vim.api.nvim_win_get_cursor(state.panel.win)[1]
  local target = Navigation.move(
    state.panel.id_by_line,
    current,
    direction == 'j' and 1 or -1
  )
  if target then vim.api.nvim_win_set_cursor(state.panel.win, { target.lnum, 0 }) end
end

---@param state table
---@param edge 'first'|'last'
local function goto_file_edge(state, edge)
  if not state.panel or not state.panel.win then return end
  if not vim.api.nvim_win_is_valid(state.panel.win) then return end
  local target = Navigation.edge(state.panel.id_by_line, edge, function(id)
    return id and id.node and not id.node.is_dir
  end)
  if target then vim.api.nvim_win_set_cursor(state.panel.win, { target.lnum, 0 }) end
end

---@param state table
---@return table?
function L.id_under_cursor(state)
  if not state.panel or not state.panel.win then return nil end
  if not vim.api.nvim_win_is_valid(state.panel.win) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(state.panel.win)[1]
  return state.panel.id_by_line and state.panel.id_by_line[lnum]
end

---@param state table
---@param M table
---@param enabled boolean
function L.set_init_enabled(state, M, enabled)
  local buf = state.panel and state.panel.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  pcall(vim.keymap.del, 'n', 'i', { buffer = buf })
  if enabled then
    vim.keymap.set('n', 'i', function() M._init_repository() end, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = 'vv-git: init_repository',
    })
  else
    local custom = M._config and M._config.mappings and M._config.mappings.i
    if type(custom) == 'function' then
      vim.keymap.set('n', 'i', function() custom(state) end, {
        buffer = buf, silent = true, nowait = true, desc = 'vv-git: custom: i',
      })
    else
      vim.keymap.set('n', 'i', '<Nop>', { buffer = buf, nowait = true })
    end
  end
end

---@param state table
---@param M table
---@param enabled boolean
function L.set_parent_enabled(state, M, enabled)
  local buf = state.panel and state.panel.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  pcall(vim.keymap.del, 'n', 'p', { buffer = buf })
  if enabled then
    vim.keymap.set('n', 'p', function() M._open_parent_repository() end, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = 'vv-git: open_parent_repository',
    })
  else
    local custom = M._config and M._config.mappings and M._config.mappings.p
    if type(custom) == 'function' then
      vim.keymap.set('n', 'p', function() custom(state) end, {
        buffer = buf, silent = true, nowait = true, desc = 'vv-git: custom: p',
      })
    else
      vim.keymap.set('n', 'p', function() M._push() end, {
        buffer = buf, silent = true, nowait = true, desc = 'vv-git: push',
      })
    end
  end
end

---@param state table
---@param M table
function L.set_repository_setup(state, M)
  L.set_init_enabled(state, M, state.init_root ~= nil)
  L.set_parent_enabled(state, M, state.parent_root ~= nil)
end

---@param state table
---@param M table
function L.install(state, M)
  local buf = state.panel.buf
  local function map(lhs, fn, action)
    vim.keymap.set('n', lhs, fn, {
      buffer = buf, silent = true, nowait = true,
      desc = 'vv-git: ' .. action,
    })
  end

  map('j',             function() navigate(state, 'j') end,       'next_item')
  map('k',             function() navigate(state, 'k') end,       'prev_item')
  map('<C-n>',         function() navigate(state, 'j') end,       'next_item')
  map('<C-p>',         function() navigate(state, 'k') end,       'prev_item')
  map('gg',            function() goto_file_edge(state, 'first') end, 'first_file')
  map('G',             function() goto_file_edge(state, 'last') end,  'last_file')
  -- 方向键 ↑↓ 与 j/k 同义（跳到上/下一个可选项）
  map('<Down>',        function() navigate(state, 'j') end,       'next_item')
  map('<Up>',          function() navigate(state, 'k') end,       'prev_item')
  map('q',             function() M.close() end,                   '__close')
  map('<Esc>',         function()
    if state.compare then
      M._compare_stop()
    elseif next(state.selection) then
      state.selection = {}
      LeftRender.render(state)
    else
      M.close()
    end
  end,                                                              '__close')
  map('R',             function() M.refresh() end,                 'refresh')
  map('<CR>',          function() M._activate() end,               'open')
  map('o',             function() M._system_open() end,            'system_open')
  map('X',             function() M._execute() end,               'execute')
  map('l',             function() M._activate(true) end,           'expand')
  map('<Right>',       function() M._activate(true) end,           'expand')   -- → 同 l
  map('<LeftRelease>', function()
    local id = L.id_under_cursor(state)
    if id and (id.section_header or id.block_header or (id.node and id.node.is_dir)) then M._toggle_fold() end
  end,                                                              'click_toggle')

  if M._config.right_click then
    local rc_action = M._config.right_click
    map('<RightMouse>', function()
      local pos = vim.fn.getmousepos()
      if pos.line > 0 and state.panel and state.panel.win then
        pcall(vim.api.nvim_win_set_cursor, state.panel.win, { pos.line, 0 })
      end
      M._action(rc_action)
    end,                                                            rc_action)
  end

  -- 屏蔽鼠标拖拽 / 多击触发 visual 选区——与 right_click 无关，恒装（面板已聚焦时干净拦截）
  -- 必须含 <3-LeftMouse>/<4-LeftMouse>：三击=选行、四击=选块，漏了「快速点几下」会误触发
  for _, key in ipairs({ '<LeftDrag>', '<2-LeftMouse>', '<3-LeftMouse>', '<4-LeftMouse>', '<RightRelease>', '<2-RightMouse>', '<3-RightMouse>', '<4-RightMouse>' }) do
    vim.keymap.set({ 'n', 'x' }, key, '<Nop>', { buffer = buf, silent = true })
  end
  vim.keymap.set('x', '<RightMouse>', '<Esc>', { buffer = buf, silent = true })
  -- 跨窗口「从别窗点进树再拖 / 多击」时上面的 buffer-local 映射拦不住（按下事件走源窗口
  -- keymap），靠 ModeChanged 守卫兜底：面板内一旦进 visual 立即退回 normal
  require('vv-utils.mouse').block_visual_drag(buf)

  map('gf',            function() M._goto_file() end,              'goto_file')
  map('Y',             function() M._yank_abs_path() end,           'yank_abs_path')
  map(M._config.keymap_select, function() M._toggle_select() end,  'toggle_select')
  map('h',             function() M._collapse() end,               'close_node')
  map('<Left>',        function() M._collapse() end,               'close_node')  -- ← 同 h
  map('zR',            function() M._toggle_diff_folds() end,      'toggle_diff_folds')
  map('-',             function() M._action('toggle_stage') end,   'toggle_stage')
  map('d',             function() M._action('discard') end,        'discard')
  map('<',             function() M._action('accept_ours') end,    'accept_ours')
  map('>',             function() M._action('accept_theirs') end,  'accept_theirs')
  map('c',             function() M._commit() end,                 'commit')
  map('p',             function() M._push() end,                   'push')
  map('P',             function() M._pull() end,                   'pull')
  map('u',             function() M._publish() end,                'publish')
  map('<C-e>',         function() scroll_diff(1) end,               'scroll_diff_down')
  map('<C-y>',         function() scroll_diff(-1) end,              'scroll_diff_up')
  map(']c',            function() jump_chunk(']') end,              'next_chunk')
  map('[c',            function() jump_chunk('[') end,              'prev_chunk')
  map('H',             function() M._compare_pick() end,           'compare_pick')
  map('gc',            function() M._commit_show_pick() end,        'commit_show')
  map('gw',            function() M._worktree_pick() end,           'worktree_pick')
  map('g?',            function() Help.open(state) end,            'help')

  for _, key in ipairs({ 'I', 'a', 'A', 'O', 'S', 'C' }) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, nowait = true })
  end
  for _, key in ipairs({ 'v', 'V', '<C-v>' }) do
    vim.keymap.set('n', key, '<Nop>', { buffer = buf, silent = true })
  end

  for lhs, action in pairs(M._config.mappings or {}) do
    if type(action) == 'function' then
      map(lhs, function() action(state) end, 'custom: ' .. lhs)
    end
  end
  -- 初始化/祖先仓库决策页的提示必须与实际按键一致，因此在自定义映射之后覆盖 i/p；
  -- 进入正常仓库时 set_repository_setup 会恢复用户自定义映射或内置 push/Nop
  L.set_repository_setup(state, M)

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = State.guarded(function(s) M._preview_on_move() end),
    desc = 'vv-git: preview on cursor move',
  })
end

return L
