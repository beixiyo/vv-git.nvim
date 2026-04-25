-- g? 键浮窗：委托给 vv-utils.help_panel
-- action 分类/图标、title 等 vv-git 特有的数据在这里维护

local HelpPanel = require('vv-utils.help_panel')

local M = {}

local ACTIONS = {
  open          = { cat = 'Navigate', icon = '' },
  close_node    = { cat = 'Navigate', icon = '' },
  toggle_fold   = { cat = 'Navigate', icon = '' },
  goto_file     = { cat = 'Navigate', icon = '' },
  toggle_stage  = { cat = 'Git',      icon = '' },
  discard       = { cat = 'Git',      icon = '' },
  commit        = { cat = 'Git',      icon = '' },
  push          = { cat = 'Remote',   icon = '' },
  pull          = { cat = 'Remote',   icon = '' },
  yank_abs_path = { cat = 'Yank',     icon = '' },
  refresh       = { cat = 'View',     icon = '' },
  help          = { cat = 'View',     icon = '' },
  __close       = { cat = 'View',     icon = '' },
}

local CATEGORIES = { 'Navigate', 'Git', 'Remote', 'Yank', 'View' }

---@param state table
function M.open(state)
  if not (state and state.panel and state.panel.buf) then return end
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
