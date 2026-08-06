-- Runtime regression for panel operations reading injected configuration

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local shown = {}
local last_show
local toggled_id
local toggled_ids = {}
local staged_node = { relpath = 'src/main.lua', is_dir = false, xy = 'M ' }
local next_node = { relpath = 'src/next.lua', is_dir = false, xy = ' M' }
local binary_node = { relpath = 'assets/image.png', is_dir = false, xy = ' M' }
local node = { relpath = 'src/main.lua', is_dir = false }
local id = {
  node = node,
  section = 'unstaged',
  base = 'unstaged',
}

package.loaded['vv-git.right.view'] = {
  show = function(_, shown_node, section, narrow, owner)
    shown[#shown + 1] = narrow
    last_show = { node = shown_node, section = section, owner = owner }
  end,
}
package.loaded['vv-git.left.render'] = { render = function() end }
package.loaded['vv-git.left.actions'] = {
  toggle_stage = function(_, action_id, after, settled)
    toggled_id = action_id
    toggled_ids[#toggled_ids + 1] = action_id
    if after then after() end
    if settled then settled(true) end
  end,
}
local fixed_cursor_id = id
package.loaded['vv-git.core.keymaps'] = {
  id_under_cursor = function(current_state)
    if fixed_cursor_id then return fixed_cursor_id end
    local lnum = vim.api.nvim_win_get_cursor(current_state.panel.win)[1]
    return current_state.panel.id_by_line[lnum]
  end,
}
package.loaded['vv-git.tree'] = {
  leaf_at = function(side, relpath)
    if side.kind == 'staged' and relpath == staged_node.relpath then return staged_node end
    if side.kind == 'unstaged' and relpath == next_node.relpath then return next_node end
  end,
}

package.loaded['vv-git.core.panel_ops'] = nil
local State = require('vv-git.state')
State.clear()
local state = State.create()
state.git_root = '/tmp/project'
state.panel = {
  win = vim.api.nvim_get_current_win(),
  buf = vim.api.nvim_get_current_buf(),
  id_by_line = {
    [2] = id,
    [3] = {
      node = binary_node,
      section = 'staged',
      base = 'staged',
    },
    [4] = {
      node = next_node,
      section = 'unstaged',
      base = 'unstaged',
    },
  },
}
vim.api.nvim_buf_set_lines(state.panel.buf, 0, -1, false, {
  'Changes',
  'src/main.lua',
  'assets/image.png',
  'src/next.lua',
})
state.folds = {}
state.tree = {
  staged = { kind = 'staged' },
  unstaged = { kind = 'unstaged' },
  conflicts = { kind = 'conflicts' },
}

local config = {
  preview = true,
  preview_debounce_ms = 10,
  single_col_threshold = vim.o.columns + 1,
  binary = { intercept = true, extensions = { png = true } },
}
local operations = require('vv-git.core.panel_ops').new({
  controller = {},
  config = function() return config end,
})

operations._preview_on_move()
assert(
  vim.wait(200, function() return #shown == 1 end),
  'debounced preview must execute with injected config'
)
assert(shown[1] == true, 'preview reads single_col_threshold from injected config')

config.single_col_threshold = 0
operations._activate()
assert(shown[2] == false, 'activate reads the latest injected config')

vim.api.nvim_win_set_cursor(state.panel.win, { 2, 0 })
last_show = nil
operations._navigate_view_file(1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 3,
  'right-buffer next file includes binary info nodes'
)
assert(
  last_show and last_show.node == binary_node and last_show.section == 'staged',
  'right-buffer next file previews the next leaf'
)
operations._navigate_view_file(1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 4,
  'right-buffer next file advances past the binary info node'
)
operations._navigate_view_file(1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 2,
  'right-buffer next file wraps to the first leaf'
)
operations._navigate_view_file(-1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 4,
  'right-buffer previous file wraps to the last leaf'
)
vim.api.nvim_win_set_cursor(state.panel.win, { 2, 0 })

state.view = {
  node = node,
  section = 'unstaged',
  root = state.git_root,
}
operations._toggle_view_stage()
assert(toggled_id and toggled_id.node == node, 'right-buffer stage uses the current view node')
assert(toggled_id.base == 'unstaged', 'right-buffer stage uses the current view section')
assert(
  last_show and last_show.node == next_node
    and last_show.section == 'unstaged'
    and last_show.owner == state.git_root,
  'right-buffer stage advances to the next file in the original section'
)
assert(
  state._action_hint and state._action_hint.next_path == next_node.relpath,
  'right-buffer stage gives the panel the same next-file action hint'
)

-- 左面板无等待连续 `-`：第一次调用返回前就同步推进光标，下一次捕获下一个文件
fixed_cursor_id = nil
toggled_ids = {}
state._action_hint = nil
vim.api.nvim_win_set_cursor(state.panel.win, { 2, 0 })
operations._action('toggle_stage')
operations._action('toggle_stage')
assert(toggled_ids[1] and toggled_ids[1].node == node,
  'first rapid panel stage captures the current file')
assert(toggled_ids[2] and toggled_ids[2].node == next_node,
  'second rapid panel stage captures the synchronously advanced file')

state.panel.id_by_line = { [2] = id }
state.view = {
  node = node,
  section = 'unstaged',
  root = state.git_root,
}
last_show = nil
operations._toggle_view_stage()
assert(
  last_show and last_show.node == staged_node and last_show.section == 'staged',
  'right-buffer stage keeps showing the moved file when its section has no neighbor'
)

State.clear()
print('vv-git panel operations config: PASS')
