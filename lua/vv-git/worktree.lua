-- worktree.lua — 管理当前仓库的 git worktree：创建、切换、删除与刷新

local Git = require('vv-git.git')

local git_icons = require('vv-icons').raw.git
local BRANCH_ICON = (git_icons.git_branches or {}).glyph or ''
local BRANCH_ICON_HL = (git_icons.git_branches or {}).hl or 'VVGitPanelBranch'
local CUR_MARK = '●'
local DESC = 'vv-git-worktree: '
local FOOTER_TEXT = ' ↵ switch  a add  d remove  r refresh  ? help '
local FOOTER = {
  { ' ↵ ', 'VVGitWorktreeFooterKey' },
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

local function default_path(root, branch, config)
  local resolver = config and config.path
  if type(resolver) ~= 'function' then
    local short = branch:match('/([^/]+)$') or branch
    return vim.fs.joinpath(root, '.worktrees', short)
  end
  local ok, path = pcall(resolver, root, branch)
  if ok and type(path) == 'string' and path ~= '' then return vim.fs.normalize(path) end
  vim.notify('[vv-git] worktree.path must return a non-empty path; using the default', vim.log.levels.WARN)
  local short = branch:match('/([^/]+)$') or branch
  return vim.fs.joinpath(root, '.worktrees', short)
end

local function input(opts, cb)
  vim.ui.input(opts, function(value)
    value = value and vim.trim(value) or ''
    if value ~= '' then cb(value) end
  end)
end

local function create_worktree(root, layout_root, refresh, config)
  vim.ui.select({ 'Existing branch', 'New branch' }, { prompt = 'Create worktree:' }, function(kind)
    if not kind then return end
    Git.branches(root, function(branches, err)
      if not branches then
        vim.notify('[vv-git] ' .. (err or 'No branches found'), vim.log.levels.ERROR)
        return
      end

      local function add(path, base, branch)
        Git.worktree_add(root, { path = vim.fs.normalize(path), base = base, branch = branch }, function(ok, add_err)
          if not ok then
            vim.notify('[vv-git] ' .. (add_err or 'Could not create worktree'), vim.log.levels.ERROR)
            return
          end
          vim.notify('[vv-git] Created worktree at ' .. path, vim.log.levels.INFO)
          refresh()
        end)
      end

      if kind == 'Existing branch' then
        Git.worktree_list(root, function(worktrees, list_err)
          if not worktrees then
            vim.notify('[vv-git] ' .. (list_err or 'Could not list worktrees'), vim.log.levels.ERROR)
            return
          end
          local occupied = {}
          for _, wt in ipairs(worktrees) do if wt.branch then occupied[wt.branch] = true end end
          local available = vim.tbl_filter(function(branch) return not occupied[branch] end, branches)
          if #available == 0 then
            vim.notify('[vv-git] Every local branch already has a worktree', vim.log.levels.INFO)
            return
          end
          vim.ui.select(available, { prompt = 'Branch for new worktree:' }, function(branch)
            if not branch then return end
            input({ prompt = 'Worktree path: ', default = default_path(layout_root, branch, config), completion = 'dir' }, function(path)
              add(path, branch)
            end)
          end)
        end)
        return
      end

      input({ prompt = 'New branch: ' }, function(branch)
        vim.ui.select(branches, { prompt = 'Base ref:' }, function(base)
          if not base then return end
          input({ prompt = 'Worktree path: ', default = default_path(layout_root, branch, config), completion = 'dir' }, function(path)
            add(path, base, branch)
          end)
        end)
      end)
    end, kind == 'Existing branch' and { local_only = true } or nil)
  end)
end

local function remove_worktree(root, wt, refresh)
  if wt.is_main then
    vim.notify('[vv-git] The main worktree cannot be removed', vim.log.levels.WARN)
    return
  end
  if vim.fs.normalize(wt.path) == vim.fs.normalize(root) then
    vim.notify('[vv-git] Switch to another worktree before removing the current one', vim.log.levels.WARN)
    return
  end
  if wt.locked then
    vim.notify('[vv-git] Locked worktrees must be unlocked explicitly before removal', vim.log.levels.WARN)
    return
  end

  if vim.fn.confirm('Remove worktree ' .. wt.path .. '?', '&Yes\n&No', 2) ~= 1 then return end

  Git.worktree_remove(root, wt.path, nil, function(ok, err)
    if ok then
      vim.notify('[vv-git] Removed worktree ' .. wt.path, vim.log.levels.INFO)
      refresh()
      return
    end

    -- 列表可能已被外部进程改变；重新检查 locked/dirty 后才决定是否允许 force
    Git.worktree_list(root, function(worktrees, list_err)
      if not worktrees then
        vim.notify('[vv-git] ' .. (list_err or err or 'Could not inspect worktree'), vim.log.levels.ERROR)
        return
      end

      local target
      local normalized = vim.fs.normalize(wt.path)

      for _, current in ipairs(worktrees) do
        if vim.fs.normalize(current.path) == normalized then target = current; break end
      end

      if not target then
        vim.notify('[vv-git] ' .. (err or 'Worktree no longer exists'), vim.log.levels.ERROR)
        refresh()
        return
      end

      if target.locked then
        vim.notify('[vv-git] Locked worktrees must be unlocked explicitly before removal', vim.log.levels.WARN)
        refresh()
        return
      end

      Git.worktree_dirty(target.path, function(dirty, status_err)
        if dirty ~= true then
          vim.notify('[vv-git] ' .. (status_err or err or 'Git refused to remove the worktree'), vim.log.levels.ERROR)
          return
        end
        local force_prompt = (err or 'Git refused to remove the dirty worktree') .. '\nForce removal?'
        if vim.fn.confirm(force_prompt, '&Yes\n&No', 2) ~= 1 then return end
        Git.worktree_remove(root, target.path, { force = true }, function(forced, force_err)
          if not forced then
            vim.notify('[vv-git] ' .. (force_err or 'Could not remove worktree'), vim.log.levels.ERROR)
            return
          end
          vim.notify('[vv-git] Force removed worktree ' .. target.path, vim.log.levels.WARN)
          refresh()
        end)
      end)
    end)
  end)
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
  local function close()
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local render
  local function refresh()
    refresh_id = refresh_id + 1
    local request = refresh_id
    Git.worktree_list(root, function(next_list, err)
      if request ~= refresh_id then return end
      render(next_list, err)
    end)
  end

  render = function(next_list, err)
    if not vim.api.nvim_buf_is_valid(buf) then return end
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
    if not wt then return end
    close()
    on_select(wt)
  end
  local function map(lhs, fn, action)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true, desc = DESC .. action })
  end

  map('<CR>', choose, 'switch')
  map('l', choose, 'switch')
  map('<Right>', choose, 'switch')
  map('a', function() create_worktree(root, layout_root, refresh, config) end, 'add')

  map('d', function()
    local wt = selected()
    if wt then remove_worktree(root, wt, refresh) end
  end, 'remove')

  map('r', refresh, 'refresh')

  map('?', function()
    require('vv-utils.help_panel').open({
      source_buf = buf, desc_prefix = DESC,
      actions = {
        switch = { cat = 'Worktree', icon = BRANCH_ICON }, add = { cat = 'Worktree', icon = '+' },
        remove = { cat = 'Worktree', icon = '-' }, refresh = { cat = 'View', icon = '' },
        help = { cat = 'View', icon = '' }, close = { cat = 'View', icon = '' },
      },
      categories = { 'Worktree', 'View' }, title = 'worktree keymaps',
      title_icon = BRANCH_ICON, filetype = 'vv-git-worktree-help',
    })
  end, 'help')
  map('q', close, 'close')
  map('<Esc>', close, 'close')

  refresh()
end

return M
