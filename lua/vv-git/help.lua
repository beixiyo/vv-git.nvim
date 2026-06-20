-- g? 键浮窗：委托给 vv-utils.help_panel
-- action 分类/图标、title 等 vv-git 特有的数据在这里维护

local HelpPanel = require('vv-utils.help_panel')

local M = {}

local ACTIONS = {
  next_item     = { cat = 'Navigate', icon = '' },
  prev_item     = { cat = 'Navigate', icon = '' },
  first_file    = { cat = 'Navigate', icon = '' },
  last_file     = { cat = 'Navigate', icon = '' },
  open          = { cat = 'Navigate', icon = '' },
  expand        = { cat = 'Navigate', icon = '' },
  close_node    = { cat = 'Navigate', icon = '' },
  click_toggle  = { cat = 'Navigate', icon = '' },
  goto_file     = { cat = 'Navigate', icon = '' },
  system_open   = { cat = 'Open as',  icon = '' },
  execute       = { cat = 'Open as',  icon = '󰐊' },
  toggle_select = { cat = 'Select',   icon = '󰒆' },
  toggle_stage  = { cat = 'Git',      icon = '' },
  discard       = { cat = 'Git',      icon = '' },
  commit        = { cat = 'Git',      icon = '' },
  commit_show   = { cat = 'Git',      icon = '' },
  compare_pick  = { cat = 'Git',      icon = '' },
  worktree_pick = { cat = 'Git',      icon = '󰘬' },
  accept_ours   = { cat = 'Conflict', icon = '󰅁' },
  accept_theirs = { cat = 'Conflict', icon = '󰅂' },
  push          = { cat = 'Remote',   icon = '' },
  pull          = { cat = 'Remote',   icon = '' },
  yank_abs_path = { cat = 'Yank',     icon = '' },
  scroll_diff_down = { cat = 'View',  icon = '' },
  scroll_diff_up   = { cat = 'View',  icon = '' },
  refresh       = { cat = 'View',     icon = '' },
  help          = { cat = 'View',     icon = '' },
  __close       = { cat = 'View',     icon = '' },
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
    title_icon  = '',
    filetype    = 'vv-git-help',
  })
end

return M
