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
  '注入配置下应执行防抖预览'
)
assert(shown[1] == true, '预览应从注入配置读取 single_col_threshold')

config.single_col_threshold = 0
operations._activate()
assert(shown[2] == false, '激活应读取最新注入配置')

vim.api.nvim_win_set_cursor(state.panel.win, { 2, 0 })
last_show = nil
operations._navigate_view_file(1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 3,
  '右侧缓冲区的下一文件应包含二进制信息节点'
)
assert(
  last_show and last_show.node == binary_node and last_show.section == 'staged',
  '右侧缓冲区下一文件应预览到下一个 leaf'
)
operations._navigate_view_file(1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 4,
  '右侧缓冲区下一文件应跳过二进制信息节点'
)
operations._navigate_view_file(1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 2,
  '右侧缓冲区下一文件应回绕到首个 leaf'
)
operations._navigate_view_file(-1)
assert(
  vim.api.nvim_win_get_cursor(state.panel.win)[1] == 4,
  '右侧缓冲区上一文件应回绕到最后 leaf'
)
vim.api.nvim_win_set_cursor(state.panel.win, { 2, 0 })

state.view = {
  node = node,
  section = 'unstaged',
  root = state.git_root,
}
operations._toggle_view_stage()
assert(toggled_id and toggled_id.node == node, '右侧缓冲区 stage 应使用当前视图 node')
assert(toggled_id.base == 'unstaged', '右侧缓冲区 stage 应使用当前视图 section')
assert(
  last_show and last_show.node == next_node
    and last_show.section == 'unstaged'
    and last_show.owner == state.git_root,
  '右侧缓冲区 stage 应跳转到原始 section 下一个文件'
)
assert(
  state._action_hint and state._action_hint.next_path == next_node.relpath,
  '右侧缓冲区 stage 应给 panel 提供一致的下一文件动作提示'
)

-- 左面板无等待连续 `-`：第一次调用返回前就同步推进光标，下一次捕获下一个文件
fixed_cursor_id = nil
toggled_ids = {}
state._action_hint = nil
vim.api.nvim_win_set_cursor(state.panel.win, { 2, 0 })
operations._action('toggle_stage')
operations._action('toggle_stage')
assert(toggled_ids[1] and toggled_ids[1].node == node,
  '第一次快速 panel stage 应捕获当前文件')
assert(toggled_ids[2] and toggled_ids[2].node == next_node,
  '第二次快速 panel stage 应捕获同步推进后的文件')

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
  '当原 section 无邻居节点时，右侧缓冲区 stage 应继续显示移动后的文件'
)

State.clear()
print('PASS: vv-git panel 操作配置回归')
