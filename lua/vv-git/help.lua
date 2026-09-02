-- g? 键浮窗：委托给 vv-utils.help_panel
-- action 分类/图标、title 等 vv-git 特有的数据在这里维护

local HelpPanel = require('vv-utils.help_panel')
local VVIcons = require('vv-icons')
local RawIcons = VVIcons.raw

local RawUI = RawIcons.ui
local RawGit = RawIcons.git

local function shared(cat, entry)
  return { cat = cat, icon = entry.glyph, icon_hl = entry.hl }
end

local function custom(cat, icon, icon_hl)
  return { cat = cat, icon = icon, icon_hl = icon_hl }
end

local M = {}

local ACTIONS = {
  next_item     = shared('Navigate', RawUI.move_down),
  prev_item     = shared('Navigate', RawUI.move_up),
  first_file    = shared('Navigate', RawUI.arrow_up),
  last_file     = shared('Navigate', RawUI.arrow_down),
  open          = shared('Navigate', RawUI.arrow_right),
  expand        = shared('Navigate', RawUI.fold_open),
  close_node    = shared('Navigate', RawUI.fold_closed),
  click_toggle  = shared('Navigate', RawUI.cursor),
  goto_file     = shared('Navigate', RawUI.find_file),
  system_open   = shared('Open as', RawUI.window),
  execute       = custom('Open as', '󰐊', 'MiniIconsGreen'),
  toggle_select = shared('Select', RawUI.list),
  toggle_stage  = shared('Git', RawGit.git_added),
  init_repository = shared('Git', RawGit.git_status),
  discard       = shared('Git', RawGit.git_removed),
  commit        = shared('Git', RawUI.save),
  commit_show   = shared('Git', RawGit.git_log),
  compare_pick  = shared('Git', RawGit.git_diff),
  worktree_pick = shared('Git', RawGit.git_branches),
  accept_ours   = custom('Conflict', '󰅁', 'DiagnosticWarn'),
  accept_theirs = custom('Conflict', '󰅂', 'DiagnosticWarn'),
  accept_ours_hunk   = custom('Conflict', '󰅁', 'DiagnosticWarn'),
  accept_theirs_hunk = custom('Conflict', '󰅂', 'DiagnosticWarn'),
  accept_both_hunk   = custom('Conflict', RawGit.git_branches.glyph, 'DiagnosticWarn'),
  next_file     = shared('Navigate', RawUI.move_down),
  prev_file     = shared('Navigate', RawUI.move_up),
  close         = shared('View', RawUI.quit),
  push          = custom('Remote', '󰁝', 'MiniIconsGreen'),
  pull          = custom('Remote', '󰁅', 'MiniIconsBlue'),
  publish       = custom('Remote', '󰁝', 'MiniIconsOrange'),
  yank_abs_path = shared('Yank', RawUI.copy),
  scroll_diff_down = shared('View', RawUI.move_down),
  scroll_diff_up   = shared('View', RawUI.move_up),
  next_chunk    = shared('View', RawUI.arrow_down),
  prev_chunk    = shared('View', RawUI.arrow_up),
  refresh       = custom('View', '󰑐', 'MiniIconsCyan'),
  toggle_diff_folds = shared('View', RawUI.fold_open),
  help          = shared('View', RawUI.keymaps),
  __close       = shared('View', RawUI.quit),
}

local CATEGORIES = { 'Navigate', 'Open as', 'Select', 'Git', 'Conflict', 'Remote', 'Yank', 'View' }

-- 冲突视图里用户最需要的是接受 hunk 的键位，把 Conflict 提到最前
local CONFLICT_CATEGORIES = { 'Conflict', 'Navigate', 'View', 'Git', 'Yank', 'Open as', 'Select', 'Remote' }

local FOLD_ROW = { cat = 'View', lhs = 'z*', action = 'native folds', icon = RawUI.fold_open.glyph, icon_hl = RawUI.fold_open.hl }

---@class VVGitHelpOpts
---@field source_buf? integer 读取键位的 buffer @default state.panel.buf
---@field mode? 'panel'|'diff'|'conflict' 决定分类顺序、标题与补充说明 @default 'panel'

---@param state table
---@param opts? VVGitHelpOpts
function M.open(state, opts)
  opts = opts or {}
  local mode = opts.mode or 'panel'
  local source_buf = opts.source_buf or (state and state.panel and state.panel.buf)
  if not (source_buf and vim.api.nvim_buf_is_valid(source_buf)) then return end

  local extra_rows = {}
  if mode ~= 'panel' then extra_rows[#extra_rows + 1] = FOLD_ROW end
  if mode == 'conflict' then
    extra_rows[#extra_rows + 1] = {
      cat = 'Conflict', lhs = 'Result', action = 'edit the bottom window directly, then :w',
      icon = RawUI.cursor.glyph, icon_hl = RawUI.cursor.hl,
    }
    extra_rows[#extra_rows + 1] = {
      cat = 'Conflict', lhs = 'panel < >', action = 'accept the whole file in the left panel',
      icon = '󰅁', icon_hl = 'DiagnosticWarn',
    }
  end

  HelpPanel.open({
    source_buf  = source_buf,
    desc_prefix = 'vv-git: ',
    actions     = ACTIONS,
    categories  = mode == 'conflict' and CONFLICT_CATEGORIES or CATEGORIES,
    extra_rows  = extra_rows,
    title       = mode == 'conflict' and 'vv-git conflict keymaps'
      or mode == 'diff' and 'vv-git diff keymaps'
      or 'vv-git keymaps',
    title_icon  = RawGit.git_status.glyph,
    title_icon_hl = RawGit.git_status.hl,
    filetype    = 'vv-git-help',
  })
end

return M
