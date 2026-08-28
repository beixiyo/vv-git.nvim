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

---@param state table
function M.open(state)
  if not (state and state.panel and state.panel.buf and vim.api.nvim_buf_is_valid(state.panel.buf)) then return end
  HelpPanel.open({
    source_buf  = state.panel.buf,
    desc_prefix = 'vv-git: ',
    actions     = ACTIONS,
    categories  = CATEGORIES,
    title       = 'vv-git keymaps',
    title_icon  = RawGit.git_status.glyph,
    title_icon_hl = RawGit.git_status.hl,
    filetype    = 'vv-git-help',
  })
end

return M
