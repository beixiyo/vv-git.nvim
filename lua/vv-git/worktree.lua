-- worktree.lua — 管理当前仓库的 git worktree：创建、切换、删除与刷新

local Git = require('vv-git.git')
local Keys = require('vv-utils.keys')
local Async = require('vv-utils.async')
local State = require('vv-git.state')
local Create = require('vv-git.worktree.create')
local Remove = require('vv-git.worktree.remove')

local VVIcons = require('vv-icons')
local RawIcons = VVIcons.raw
local RawUI = RawIcons.ui
local RawGit = RawIcons.git

local BRANCH_ENTRY = RawGit.git_branches or {}
local BRANCH_ICON = BRANCH_ENTRY.glyph or ''
local BRANCH_ICON_HL = BRANCH_ENTRY.hl or 'VVGitPanelBranch'

local ADD_ENTRY = RawUI.new_file or {}
local REMOVE_ENTRY = RawGit.git_removed or {}
local HELP_ENTRY = RawUI.keymaps or {}
local CLOSE_ENTRY = RawUI.quit or {}
local REFRESH_ICON = '󰑐'
local CUR_MARK = '●'

local DESC = 'vv-git-worktree: '
local SWITCH_KEY = Keys.display('<CR>')
local FOOTER_TEXT = ' ' .. SWITCH_KEY .. ' switch  a add  d remove  r refresh  ? help '
local FOOTER = {
  { ' ' .. SWITCH_KEY .. ' ', 'VVGitWorktreeFooterKey' },
  { 'switch  ', 'VVGitWorktreeFooterText' },
  { 'a ', 'VVGitWorktreeFooterKey' },
  { 'add  ', 'VVGitWorktreeFooterText' },
  { 'd ', 'VVGitWorktreeFooterKey' },
  { 'remove  ', 'VVGitWorktreeFooterText' },
  { 'r ', 'VVGitWorktreeFooterKey' },
  { 'refresh  ', 'VVGitWorktreeFooterText' },
  { '? ', 'VVGitWorktreeFooterKey' },
  { 'help ', 'VVGitWorktreeFooterText' },
}

local M = {}
local NS = vim.api.nvim_create_namespace('vv-git-worktree')

local function ref_label(wt)
  if wt.branch then return wt.branch end
  if wt.detached then return '(detached ' .. ((wt.head or '???????'):sub(1, 7)) .. ')' end
  return '(unknown)'
end

local function tilde(path)
  local home = vim.fs.normalize(vim.env.HOME or '')
  if home ~= '' and path:sub(1, #home) == home then return '~' .. path:sub(#home + 1) end
  return path
end

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
  segs[#segs + 1] = { col = #line, len = #ref, hl = wt.detached and 'WarningMsg' or (is_current and 'Title' or 'Normal') }
  line = line .. ref .. string.rep(' ', math.max(0, ref_w - vim.fn.strdisplaywidth(ref))) .. '  '
  local path = tilde(wt.path)
  segs[#segs + 1] = { col = #line, len = #path, hl = 'Comment' }
  line = line .. path
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

---@param state table
---@param on_select fun(wt: VVGitWorktree)
function M.open_manager(state, on_select, config)
  if not state.git_root then return end
  local root = vim.fs.normalize(state.git_root)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'vv-git-worktree'

  local win
  local list = {}
  local layout_root = root
  local refresh_id = 0
  local action_scope = Async.scope({ cancel_previous = true })
  local manager_closed = false
  local owner_generation = State.root_generation(state)
  local lifecycle_ids = {}

  local function is_active()
    if manager_closed then return false end
    if state.git_root ~= root or state._closing then return false end
    if State.root_generation(state) ~= owner_generation then return false end
    -- 测试和外部调用方可能只提供 `{ git_root = ... }`；仅完整打开的 vv-git state 强制单例身份。
    if state.tabpage and State.has() and not State.is_current(state) then return false end
    return vim.api.nvim_buf_is_valid(buf)
        and (not win or vim.api.nvim_win_is_valid(win))
  end

  local function close()
    if manager_closed then return end
    manager_closed = true
    action_scope:cancel()
    for _, id in ipairs(lifecycle_ids) do pcall(vim.api.nvim_del_autocmd, id) end
    lifecycle_ids = {}
    if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end

  lifecycle_ids[#lifecycle_ids + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = close,
  })
  if state.tabpage then
    lifecycle_ids[#lifecycle_ids + 1] = vim.api.nvim_create_autocmd('TabClosed', {
      callback = function()
        if not vim.api.nvim_tabpage_is_valid(state.tabpage) then close() end
      end,
    })
  end

  local render
  local function refresh()
    if manager_closed then return end
    refresh_id = refresh_id + 1
    local request = refresh_id
    Git.worktree_list(root, function(next_list, err)
      if request ~= refresh_id or not is_active() then return end
      render(next_list, err)
    end)
  end

  render = function(next_list, err)
    if not is_active() then return end
    if not next_list or #next_list == 0 then
      vim.notify('[vv-git] ' .. (err or 'No worktrees'), vim.log.levels.WARN)
      close()
      return
    end

    for _, wt in ipairs(next_list) do
      if wt.is_main and not wt.bare then layout_root = vim.fs.normalize(wt.path); break end
    end

    list = vim.tbl_filter(function(wt) return not wt.bare end, next_list)
    if #list == 0 then
      vim.notify('[vv-git] No manageable worktree (bare repo only)', vim.log.levels.WARN)
      close()
      return
    end

    local ref_w = 0
    for _, wt in ipairs(list) do ref_w = math.max(ref_w, vim.fn.strdisplaywidth(ref_label(wt))) end

    local lines, all_segs, current = {}, {}, 1

    for i, wt in ipairs(list) do
      local is_current = vim.fs.normalize(wt.path) == root
      if is_current then current = i end
      lines[i], all_segs[i] = render_line(wt, is_current, ref_w)
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

    for row, segs in ipairs(all_segs) do
      for _, segment in ipairs(segs) do
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, segment.col, {
          end_col = segment.col + segment.len,
          hl_group = segment.hl,
        })
      end
    end
    vim.bo[buf].modifiable = false

    local width = math.max(48, vim.fn.strdisplaywidth(FOOTER_TEXT))
    for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line) + 2) end

    width = math.min(width, math.max(1, vim.o.columns - 8))
    local height = math.min(#lines, math.max(1, vim.o.lines - 8))
    local window_config = {
      relative = 'editor',
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
    }

    if not win or not vim.api.nvim_win_is_valid(win) then
      win = vim.api.nvim_open_win(buf, true, vim.tbl_extend('force', window_config, {
        style = 'minimal',
        border = 'rounded',
        title = ' Worktrees ',
        title_pos = 'center',
        footer = FOOTER,
        footer_pos = 'center',
      }))
      require('vv-utils.ui_window').hide_chrome(win, { cursorline = true })
      require('vv-utils.mouse').block_visual_drag(buf)
    else
      vim.api.nvim_win_set_config(win, window_config)
    end
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(current, #list), 0 })
  end

  local function selected()
    if not win or not vim.api.nvim_win_is_valid(win) then return nil end
    return list[vim.api.nvim_win_get_cursor(win)[1]]
  end

  local function choose()
    local wt = selected()
    if not wt or not is_active() then return end
    close()
    on_select(wt)
  end
  local function map(lhs, fn, action)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = DESC .. action })
  end

  map('<CR>', choose, 'switch')
  map('l', choose, 'switch')
  map('<Right>', choose, 'switch')
  map('a', function()
    Create.run(root, layout_root, refresh, config, {
      is_active = is_active,
      begin = function() return action_scope:begin({ key = 'action' }) end,
    })
  end, 'add')

  map('d', function()
    local wt = selected()
    if wt then
      Remove.run(root, wt, refresh, {
        is_active = is_active,
        begin = function() return action_scope:begin({ key = 'action' }) end,
      })
    end
  end, 'remove')

  map('r', refresh, 'refresh')

  map('?', function()
    require('vv-utils.help_panel').open({
      source_buf = buf, desc_prefix = DESC,
      actions = {
        switch = { cat = 'Worktree', icon = BRANCH_ENTRY.glyph or '', icon_hl = BRANCH_ENTRY.hl },
        add = { cat = 'Worktree', icon = ADD_ENTRY.glyph or '', icon_hl = ADD_ENTRY.hl },
        remove = { cat = 'Worktree', icon = REMOVE_ENTRY.glyph or '', icon_hl = REMOVE_ENTRY.hl },
        refresh = { cat = 'View', icon = REFRESH_ICON, icon_hl = 'MiniIconsCyan' },
        help = { cat = 'View', icon = HELP_ENTRY.glyph or '', icon_hl = HELP_ENTRY.hl },
        close = { cat = 'View', icon = CLOSE_ENTRY.glyph or '', icon_hl = CLOSE_ENTRY.hl },
      },
      categories = { 'Worktree', 'View' }, title = 'worktree keymaps',
      title_icon = BRANCH_ICON, title_icon_hl = BRANCH_ICON_HL, filetype = 'vv-git-worktree-help',
    })
  end, 'help')
  map('q', close, 'close')
  map('<Esc>', close, 'close')

  refresh()
end

return M
