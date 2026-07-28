-- Runtime regression for panel operations reading injected configuration

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(root)

local shown = {}
local last_show
local toggled_id
local staged_node = { relpath = 'src/main.lua', is_dir = false, xy = 'M ' }
local next_node = { relpath = 'src/next.lua', is_dir = false, xy = ' M' }
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
  toggle_stage = function(_, action_id, after)
    toggled_id = action_id
    after()
  end,
}
package.loaded['vv-git.core.keymaps'] = {
  id_under_cursor = function() return id end,
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
      node = next_node,
      section = 'unstaged',
      base = 'unstaged',
    },
  },
}
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
  binary = { intercept = false, extensions = {} },
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
