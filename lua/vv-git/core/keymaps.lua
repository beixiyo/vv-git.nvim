-- panel buffer-local 快捷键 + 辅助函数（scroll_diff / navigate / id_under_cursor）

local State = require('vv-git.state')
local RightView = require('vv-git.right.view')
local LeftRender = require('vv-git.left.render')
local Help = require('vv-git.help')

local L = {}

local CE_KEY = vim.api.nvim_replace_termcodes('<C-e>', true, false, true)
local CY_KEY = vim.api.nvim_replace_termcodes('<C-y>', true, false, true)

---@param keys string
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
---@param direction 'j'|'k'
local function navigate(state, direction)
  if not state.panel or not state.panel.win then return end
  if not vim.api.nvim_win_is_valid(state.panel.win) then return end
  local id_by_line = state.panel.id_by_line
  if not id_by_line then return end

  local lnums = {}
  for lnum, _ in pairs(id_by_line) do
    lnums[#lnums + 1] = lnum
  end
  if #lnums == 0 then return end
  table.sort(lnums)

  local cur = vim.api.nvim_win_get_cursor(state.panel.win)[1]

  if direction == 'j' then
    for _, lnum in ipairs(lnums) do
      if lnum > cur then
        vim.api.nvim_win_set_cursor(state.panel.win, { lnum, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(state.panel.win, { lnums[1], 0 })
  else
    for i = #lnums, 1, -1 do
      if lnums[i] < cur then
        vim.api.nvim_win_set_cursor(state.panel.win, { lnums[i], 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(state.panel.win, { lnums[#lnums], 0 })
  end
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
  map('q',             function() M.close() end,                   '__close')
  map('<Esc>',         function()
    if state.compare then
      require('vv-git.compare').stop(state)
      state.selection = {}
      RightView.close(state)
      LeftRender.render(state)
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
  map('<LeftRelease>', function()
    local id = L.id_under_cursor(state)
    if id and (id.section_header or (id.node and id.node.is_dir)) then M._toggle_fold() end
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

    for _, key in ipairs({ '<LeftDrag>', '<2-LeftMouse>', '<RightRelease>', '<2-RightMouse>', '<3-RightMouse>', '<4-RightMouse>' }) do
      vim.keymap.set({ 'n', 'x' }, key, '<Nop>', { buffer = buf, silent = true })
    end
    vim.keymap.set('x', '<RightMouse>', '<Esc>', { buffer = buf, silent = true })
  end

  map('gf',            function() M._goto_file() end,              'goto_file')
  map('Y',             function() M._yank_abs_path() end,           'yank_abs_path')
  map(M._config.keymap_select, function() M._toggle_select() end,  'toggle_select')
  map('h',             function() M._collapse() end,               'close_node')
  map('-',             function() M._action('toggle_stage') end,   'toggle_stage')
  map('d',             function() M._action('discard') end,        'discard')
  map('<',             function() M._action('accept_ours') end,    'accept_ours')
  map('>',             function() M._action('accept_theirs') end,  'accept_theirs')
  map('c',             function() M._commit() end,                 'commit')
  map('p',             function() M._push() end,                   'push')
  map('P',             function() M._pull() end,                   'pull')
  map('<C-e>',         function() scroll_diff(CE_KEY) end,         'scroll_diff_down')
  map('<C-y>',         function() scroll_diff(CY_KEY) end,         'scroll_diff_up')
  map('H',             function() M._compare_pick() end,           'compare_pick')
  map('gc',            function() M._commit_show_pick() end,        'commit_show')
  map('g?',            function() Help.open(state) end,            'help')

  for _, key in ipairs({ 'i', 'I', 'a', 'A', 'O', 'S', 'C' }) do
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

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = State.guarded(function(s) M._preview_on_move() end),
    desc = 'vv-git: preview on cursor move',
  })
end

return L
