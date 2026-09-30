-- 预览触发节奏：单独一次 j/k 立即预览，按住连切时防抖、停下只预览最后一个文件
-- 用法: cd vv-git.nvim && nvim --headless -u NONE -l tests/test_preview_debounce.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
local vendors = vim.fn.fnamemodify(root, ':h')
vim.opt.runtimepath:prepend(vendors .. '/vv-utils.nvim')
vim.opt.runtimepath:prepend(vendors .. '/vv-icons.nvim')
vim.opt.runtimepath:prepend(root)

local shown = {}
package.loaded['vv-git.right.view'] = {
  show = function(_, node) shown[#shown + 1] = node.relpath end,
}
package.loaded['vv-git.core.keymaps'] = {
  id_under_cursor = function(state)
    return state.panel.id_by_line[vim.api.nvim_win_get_cursor(state.panel.win)[1]]
  end,
}

package.loaded['vv-git.core.panel_ops'] = nil
local State = require('vv-git.state')
State.clear()
local state = State.create()
state.git_root = '/tmp/project'
state.panel = { win = vim.api.nvim_get_current_win(), buf = vim.api.nvim_get_current_buf(), id_by_line = {} }

local lines = {}
for i = 1, 6 do
  local relpath = 'f' .. i .. '.lua'
  lines[i] = relpath
  state.panel.id_by_line[i] = {
    node = { relpath = relpath, is_dir = false, xy = ' M' },
    section = 'unstaged',
    base = 'unstaged',
  }
end
vim.api.nvim_buf_set_lines(state.panel.buf, 0, -1, false, lines)

local WAIT = 150
local operations = require('vv-git.core.panel_ops').new({
  controller = {},
  config = function() return { preview = true, preview_debounce_ms = WAIT, single_col_threshold = 0 } end,
})

local function move_to(lnum)
  vim.api.nvim_win_set_cursor(state.panel.win, { lnum, 0 })
  operations._preview_on_move()
end

-- 单按：同步预览，不等防抖
move_to(1)
assert(#shown == 1 and shown[1] == 'f1.lua', '单独一次移动应立即预览，实际 ' .. vim.inspect(shown))

-- 停够防抖窗口后再单按：仍立即预览
vim.wait(WAIT + 100)
move_to(2)
assert(#shown == 2 and shown[2] == 'f2.lua', '间隔超过防抖窗口的移动应立即预览，实际 ' .. vim.inspect(shown))

-- 按住连切：窗口内的后续移动都不立即预览，停下后只预览最后一个
vim.wait(WAIT + 100)
move_to(3)
assert(#shown == 3, '连切的第一下应立即预览')
for lnum = 4, 6 do
  vim.wait(20)
  move_to(lnum)
end
assert(#shown == 3, '连切途中不应立即预览，实际 ' .. vim.inspect(shown))
assert(vim.wait(WAIT + 300, function() return #shown == 4 end), '停下后应补一次预览')
vim.wait(WAIT)
assert(#shown == 4 and shown[4] == 'f6.lua', '停下后只预览最后一个文件，实际 ' .. vim.inspect(shown))

State.clear()
print('PASS: vv-git 预览触发节奏')
